# tenant-a/namespaces/

## What this block does

Creates the application and ingress gateway namespaces for tenant-a.
These namespaces must exist and be correctly labelled before deploying
any workloads, gateways, or policies.

All findings are from actual lab observations on spoke1.

---

## Lab environment

```
Cluster:   spoke1 (multi-node, platform: AWS)
OCP:       4.20
Source:    service-mesh-3.2/gateways/ingress/bookinfo-namespace.yaml (patched)
```

---

## Files in this directory

| File | Kind | What it deploys |
|---|---|---|
| bookinfo-a.yaml | Namespace | bookinfo-a — tenant-a app namespace |
| bookinfo-ingress-a.yaml | Namespace | bookinfo-ingress-a — tenant-a ingress gateway namespace |

---

## What changed from SNO

### Label strategy change — istio-discovery=enabled → mesh=tenant-a

SNO used a single label for all namespaces:
```yaml
labels:
  istio-discovery: enabled    # SNO — all namespaces use this
```

Multi-tenant workload namespaces use:
```yaml
labels:
  mesh: tenant-a              # istiod-a Category 2 discoverySelector
```

Why the change:
- istiod-a discoverySelector Category 2 matches `mesh=tenant-a`
- istiod-b discoverySelector Category 2 matches `mesh=tenant-b`
- Using `istio-discovery=enabled` on all namespaces would make
  BOTH istiod-a and istiod-b watch the same namespaces —
  breaking tenant isolation at the control plane level

### Name change

| SNO | tenant-a |
|---|---|
| bookinfo | bookinfo-a |
| bookinfo-ingress | bookinfo-ingress-a |

### AWS vs SNO ingress namespace

SNO bookinfo-ingress had `istio-discovery=enabled` because the
platform:None gateway Service needed a ClusterIP annotation and
an OCP Route on top.

On AWS the Gateway API controller creates a LoadBalancer Service
automatically. AWS provisions an NLB. No OCP Route needed.
The namespace label changes to `mesh=tenant-a` but the purpose
and structure remain the same.

---

## Apply order

```bash
# Create namespaces
oc apply -f bookinfo-a.yaml
oc apply -f bookinfo-ingress-a.yaml

# Verify labels
oc get namespace bookinfo-a bookinfo-ingress-a --show-labels

# Deploy bookinfo app into bookinfo-a
oc apply -n bookinfo-a -f \
  https://raw.githubusercontent.com/istio/istio/release-1.27/samples/bookinfo/platform/kube/bookinfo.yaml

# Verify pods are 1/1 (ambient — no sidecars)
oc get pods -n bookinfo-a
```

---

## Verify

```bash
# Namespaces exist with correct labels
oc get namespace bookinfo-a bookinfo-ingress-a --show-labels

# bookinfo-a pods are 1/1 — ambient enrolled, no sidecars
oc get pods -n bookinfo-a
# All pods: 1/1 Running

# istiod-a can see bookinfo-a workloads
# (run after bookinfo is deployed)
oc logs -n istio-system-a deploy/istiod-tenant-a | grep "bookinfo-a" | tail -5

# ztunnel sees bookinfo-a pods as HBONE
istioctl ztunnel-config workloads \
  $(oc get pods -n ztunnel -o jsonpath='{.items[0].metadata.name}').ztunnel \
  --workload-namespace bookinfo-a
# All pods: PROTOCOL=HBONE
```

---

## What to do next

```
tenant-a/gateways/   Deploy Waypoint + ingress gateway
```

---

## Lesson learned — bookinfo pods schedule on infra node by default

The upstream bookinfo manifest has no nodeSelector or tolerations.
On first deploy all 6 pods landed on the infra node (ip-10-0-57-92)
because it has no taint — pods schedule there freely.

The infra node has NO ztunnel pod. Pods there are completely outside
the mesh — no mTLS, no SPIFFE identity, no policy enforcement.

```
# OBSERVED — all pods on infra node, outside mesh
ip-10-0-57-92.ec2.internal   details-v1       1/1  (no ztunnel here)
ip-10-0-57-92.ec2.internal   productpage-v1   1/1  (no ztunnel here)
...
```

Fix — apply bookinfo-patch-a.yaml immediately after bookinfo deploy:

```bash
# 1. Deploy bookinfo
oc apply -n bookinfo-a -f \
  https://raw.githubusercontent.com/istio/istio/release-1.27/samples/bookinfo/platform/kube/bookinfo.yaml

# 2. Immediately patch nodeSelector + tolerations
oc apply -f bookinfo-patch-a.yaml

# Verify — all pods on tenant-a nodes only
oc get pods -n bookinfo-a -o wide
# All pods: ip-10-0-0-5 or ip-10-0-19-190 only
```

---

## Verified output

```
NAME                              READY   NODE
details-v1-5db68946bb-mmdnp       1/1     ip-10-0-19-190.ec2.internal
productpage-v1-746f5dc967-blw6q   1/1     ip-10-0-19-190.ec2.internal
ratings-v1-7ff8486b5d-tr5gk       1/1     ip-10-0-19-190.ec2.internal
reviews-v1-6dfc7f5886-tcc6h       1/1     ip-10-0-19-190.ec2.internal
reviews-v2-587d4956cd-h9nqf       1/1     ip-10-0-19-190.ec2.internal
reviews-v3-7dcf7bcf54-5wk4q       1/1     ip-10-0-19-190.ec2.internal
```

All pods 1/1 — ambient enrolled (no sidecars), on tenant-a nodes. ✅

ztunnel workload verification — all pods HBONE enrolled:
```
NAMESPACE  POD NAME                          NODE                        WAYPOINT  PROTOCOL
bookinfo-a details-v1-5db68946bb-mmdnp      ip-10-0-19-190.ec2.internal None      HBONE
bookinfo-a productpage-v1-746f5dc967-blw6q  ip-10-0-19-190.ec2.internal None      HBONE
bookinfo-a ratings-v1-7ff8486b5d-tr5gk      ip-10-0-19-190.ec2.internal None      HBONE
bookinfo-a reviews-v1-6dfc7f5886-tcc6h      ip-10-0-19-190.ec2.internal None      HBONE
bookinfo-a reviews-v2-587d4956cd-h9nqf      ip-10-0-19-190.ec2.internal None      HBONE
bookinfo-a reviews-v3-7dcf7bcf54-5wk4q      ip-10-0-19-190.ec2.internal None      HBONE
```

WAYPOINT=None is expected at this stage — Waypoint deployed in tenant-a/gateways/
PROTOCOL=HBONE confirms ztunnel is intercepting all bookinfo-a traffic ✅
