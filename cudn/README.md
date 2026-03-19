# CUDN — Cluster User Defined Networks

Layer 2 secondary network isolation per tenant.
Deployed as Phase 1 before Istio ambient mode.

## Files

```
cudn/
├── cudn-tenant-a.yaml          10.200.1.0/24  selects mesh=tenant-a
├── cudn-tenant-b.yaml          10.200.2.0/24  selects mesh=tenant-b
├── network-config-verify.sh    pre-flight IP conflict check
└── README.md
```

## Verified subnet allocations

| CUDN            | Subnet          | Namespaces                              | Node pool      |
|-----------------|-----------------|-----------------------------------------|----------------|
| cudn-tenant-a   | 10.200.1.0/24   | bookinfo-a, bookinfo-ingress-a          | worker-89pfx-3/4 |
| cudn-tenant-b   | 10.200.2.0/24   | bookinfo-b, bookinfo-ingress-b          | worker-89pfx-5/6 |
| future tenant-c | 10.200.3.0/24   | —                                       | —              |

Conflict check run against:
- clusterNetwork  `10.232.0.0/14`  — clean
- serviceNetwork  `172.231.0.0/16` — clean
- OVN-K internal  `100.64.0.0/16`  — clean
- node IPs        `10.10.10.0/24`  — clean
- worker node routes                — clean (empty on all 4 tenant nodes)

## Design decisions

**Why CUDN and not UDN?**
Each tenant has two namespaces (workload + ingress). CUDN spans
both with a single CR and a single L2 segment. UDN would require
one object per namespace (4 total) and the gateway/workload
namespaces would be on different segments, requiring extra routing
config on top of the existing ReferenceGrant + HTTPRoute setup.

**Why Secondary role?**
Primary UDN replaces the pod network. ztunnel's HBONE mechanism
depends on pod IPs being reachable on the primary OVN-K interface.
Secondary adds a second interface — ztunnel operates on primary,
CUDN traffic flows on secondary. Both coexist without conflict.

**Why Layer2?**
Layer2 topology gives all pods in the selected namespaces a shared
L2 domain across nodes. Gateway pod in bookinfo-ingress-a and
workload pods in bookinfo-a can communicate directly at L2 without
needing a router hop, preserving the existing HTTPRoute behaviour.

**namespaceSelector uses existing label**
`mesh: tenant-a/b` is already stamped by the TenantNamespace CR
in mto-integration/. No new labels are needed — MTO stamps the
label, CUDN selects it automatically.

## Apply order

```bash
# 1. pre-flight check (already passing — run again after any cluster change)
./cudn/network-config-verify.sh

# 2. apply CUDNs
oc apply -f cudn/cudn-tenant-a.yaml
oc apply -f cudn/cudn-tenant-b.yaml

# 3. watch until both show Ready
oc get clusteruserdefinednetwork -w

# 4. verify NAD was injected into tenant namespaces
oc get net-attach-def -n bookinfo-a
oc get net-attach-def -n bookinfo-ingress-a
oc get net-attach-def -n bookinfo-b
oc get net-attach-def -n bookinfo-ingress-b

# 5. verify pods received secondary interface
oc exec -n bookinfo-a deploy/productpage-v1 -- ip addr show
# expect: eth0 (primary 10.232.x.x) + net1 (secondary 10.200.1.x)
```

## Adding a new tenant

```bash
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: cudn-tenant-c
spec:
  namespaceSelector:
    matchLabels:
      mesh: tenant-c
  network:
    topology: Layer2
    layer2:
      role: Secondary
      subnets: ["10.200.3.0/24"]
EOF
```

Then add `mesh: tenant-c` to the new TenantNamespace labels in
mto-integration/tenant-c/ — CUDN picks it up automatically.

## Relationship to other layers

```
cudn/                   ← Phase 1: L2/L3 tenant isolation (this directory)
mto-integration/        ← Phase 3: namespace lifecycle + label management
shared/                 ← Phase 2: Istio ambient control plane (already deployed)
tenant-a/ tenant-b/     ← per-tenant mesh config (gateways, policy) — unchanged
```
