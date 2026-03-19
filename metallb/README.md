# MetalLB — LoadBalancer IP for Bare-Metal OCP on AWS

MetalLB provides `LoadBalancer` service type support for the
service mesh ingress gateways on a bare-metal platform type OCP
cluster running on AWS infrastructure.

---

## Directory layout

```
operator/
└── metallb-operator.yaml     OLM Subscription — in metallb-system namespace

metallb/
├── metallb-namespace.yaml    MetalLB CR — activates controller + speakers
└── metallb-pool.yaml         IPAddressPool + L2Advertisement
```

---

## Why MetalLB is needed

This cluster reports `platformSpec.type: BareMetal` even though it
runs on AWS. Bare-metal platform type means:

- No AWS cloud controller manager (`openshift-cloud-controller-manager`
  namespace is empty)
- `LoadBalancer` services stay `EXTERNAL-IP: <pending>` forever
- Istio ingress gateway pods run but are unreachable externally

MetalLB fills this gap by responding to ARP requests on the node
network and assigning real IPs from a configured pool to
`LoadBalancer` services.

---

## IP address allocation

| Service | Namespace | External IP | Subnet |
|---|---|---|---|
| bookinfo-gateway-a-istio | bookinfo-ingress-a | 10.10.10.50 | tenant-a ingress |
| bookinfo-gateway-b-istio | bookinfo-ingress-b | 10.10.10.51 | tenant-b ingress |
| future tenants | — | 10.10.10.52–10.10.10.80 | 29 slots reserved |

### Conflict verification — pool 10.10.10.50–10.10.10.80

| Range | Owner | Conflict |
|---|---|---|
| 10.10.10.10–10.10.10.35 | Node host IPs | None — pool starts at .50 |
| 10.232.0.0/14 | clusterNetwork (pod primary) | None — separate /8 block |
| 172.231.0.0/16 | serviceNetwork (ClusterIPs) | None — separate class B |
| 10.200.1.0/24 | CUDN tenant-a | None — separate /16 block |
| 10.200.2.0/24 | CUDN tenant-b | None — separate /16 block |

---

## Apply order

MetalLB operator must be installed before the MetalLB instance CR.
The instance CR must exist before the IPAddressPool.
MTO IntegrationConfig must exempt `metallb-system` before the operator
namespace is created.

```bash
# 1. Ensure metallb-system is in MTO privilegedNamespaces
#    (already in mto-integration/config/mto-integration-config.yaml)
oc apply -f mto-integration/config/mto-integration-config.yaml

# 2. Install MetalLB operator
oc apply -f operator/metallb-operator.yaml

# 3. Wait for CSV Succeeded in metallb-system
oc get csv -n metallb-system | grep metallb

# 4. Create MetalLB instance (activates controller + speakers)
oc apply -f metallb/metallb-namespace.yaml

# 5. Wait for controller + speaker pods Running
oc get pods -n metallb-system

# 6. Apply IP pool and L2 advertisement
oc apply -f metallb/metallb-pool.yaml

# 7. Verify gateway services get external IPs
oc get svc -n bookinfo-ingress-a
oc get svc -n bookinfo-ingress-b
```

Expected result:
```
bookinfo-gateway-a-istio  LoadBalancer  172.231.x.x  10.10.10.50  80:xxxxx/TCP
bookinfo-gateway-b-istio  LoadBalancer  172.231.x.x  10.10.10.51  80:xxxxx/TCP
```

---

## OperatorGroup — critical configuration

MetalLB requires `AllNamespaces` install mode. The OperatorGroup
must use `spec: {}` (empty spec) — NOT `spec.targetNamespaces`.

```yaml
# CORRECT — AllNamespaces mode
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-operator-group
  namespace: metallb-system
spec: {}

# WRONG — OwnNamespace mode (MetalLB does not support this)
spec:
  targetNamespaces:
    - metallb-system
```

### Lessons learned — OperatorGroup

**Attempt 1 — `spec.targetNamespaces: [metallb-system]`**
Result: `UnsupportedOperatorGroup — OwnNamespace InstallModeType
not supported`. MetalLB needs to watch LoadBalancer services in ALL
namespaces, not just its own.

**Attempt 2 — Subscription in `openshift-operators`**
Result: Operator installed but webhook TLS cert collisions with other
operators sharing the namespace (Tempo, OTel controllers all share the
same pod selector space). The `metallb-operator-controller-manager`
deployment matched Tempo operator pods. MetalLB instance CR apply
failed with x509 cert mismatch errors.

**Correct approach — `metallb-system` with `spec: {}`**
MetalLB gets its own isolated namespace. `spec: {}` on the
OperatorGroup means AllNamespaces. No cert or pod selector collisions.
The `metallb-system` namespace must be in MTO `privilegedNamespaces`
or the namespace creation is blocked by the MTO webhook.

---

## L2 mode — how it works

MetalLB L2 mode uses ARP (IPv4) to advertise LoadBalancer IPs
on the node network. When a client sends an ARP request for
`10.10.10.50`, one MetalLB speaker pod responds claiming that IP.

```
Client → ARP "who has 10.10.10.50?"
MetalLB speaker on worker-89pfx-3 → "I have 10.10.10.50"
Client → TCP SYN to worker-89pfx-3
kube-proxy / OVN-K → routes to bookinfo-gateway-a-istio pod
```

The `nodeSelectors` in `L2Advertisement` limits ARP responses to
worker nodes only — control plane nodes do not participate in
data plane traffic.

No BGP, no AWS routing changes, no VPC configuration needed.
Works entirely within the existing node subnet.

---

## Limitations on bare-metal OCP on AWS

MetalLB L2 IPs are reachable only from within the same L2 network
segment (the VPC subnet `10.10.10.0/24`). They are NOT reachable
from the internet or from your laptop directly.

To test from outside the cluster:

```bash
# Option 1 — port-forward (laptop access)
oc port-forward svc/bookinfo-gateway-a-istio 8080:80 \
  -n bookinfo-ingress-a
curl http://localhost:8080/productpage

# Option 2 — curl from inside cluster
oc run curl-test -n bookinfo-a \
  --image=curlimages/curl --rm -it --restart=Never \
  -- curl -s http://10.10.10.50/productpage | grep title

# Option 3 — curl from node
oc debug node/worker-cluster-89pfx-3 -- \
  chroot /host curl -s http://10.10.10.50/productpage | grep title
```

For production external access on AWS, use an OpenShift Route or
AWS ALB Ingress Controller instead of MetalLB L2.

---

## MTO integration

`metallb-system` must be in MTO `privilegedNamespaces` before
the operator namespace is created. It is already added to
`mto-integration/config/mto-integration-config.yaml`:

```yaml
spec:
  accessControl:
    privileged:
      namespaces:
        - ^metallb-system$
      serviceAccounts:
        - ^system:serviceaccount:metallb-system:.*
```

Without this, `oc apply -f operator/metallb-operator.yaml` fails
with:
```
admission webhook "vnamespace.kb.io" denied the request:
'admin' cannot 'create' namespace 'metallb-system'
without label 'stakater.com/tenant'
```

---

## Relationship to other project directories

```
operator/metallb-operator.yaml   OLM install — alongside other operators
metallb/                         MetalLB instance + IP pool config
mto-integration/config/          IntegrationConfig must exempt metallb-system
tenant-a/gateways/               bookinfo-gateway-a gets 10.10.10.50
tenant-b/gateways/               bookinfo-gateway-b gets 10.10.10.51
```
