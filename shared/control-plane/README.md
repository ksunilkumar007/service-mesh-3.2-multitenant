# shared/control-plane/

## Architecture Decision — Single Ambient Mesh

True multi-tenant ambient mode with separate ztunnel instances per tenant
is NOT supported in Istio 1.27.5 (or any current Istio release).

There can only be ONE ztunnel DaemonSet per cluster, hence only ONE ambient
mesh per cluster. This is a fundamental constraint of the ambient architecture.

Reference: https://github.com/istio/istio/issues (ambient multi-mesh)

---

## What "multi-tenancy" means in ambient mode

```
┌─────────────────────────────────────────────────────────┐
│                  Shared Layer                            │
│  istiod (default)  ──→  ztunnel DaemonSet (all nodes)  │
│  namespace: istio-system                                 │
│  ONE trust domain: cluster.local                        │
└─────────────────────────────────────────────────────────┘
              ↓ isolation via policy + scheduling
┌──────────────────────┐    ┌──────────────────────────┐
│   Tenant-A           │    │   Tenant-B               │
│   nodes: mesh=tenant-a    │   nodes: mesh=tenant-b   │
│   namespaces:        │    │   namespaces:            │
│     bookinfo-a       │    │     bookinfo-b           │
│     bookinfo-ingress-a    │     bookinfo-ingress-b   │
│   waypoint-a (L7)    │    │   waypoint-b (L7)        │
│   AuthorizationPolicy│    │   AuthorizationPolicy    │
└──────────────────────┘    └──────────────────────────┘
```

Tenant isolation is achieved via:
- Node pool separation — taint/label per tenant (scheduling isolation)
- Per-tenant waypoints — L7 policy enforcement per tenant
- AuthorizationPolicy — deny cross-tenant traffic at L7
- SPIFFE identity — scoped per namespace/serviceaccount

---

## What was tried and abandoned

### Per-tenant istiod (tenant-a + tenant-b Istio CRs)

Initially deployed separate istiod-a and istiod-b with:
- istiod-a in istio-system-a, revision: tenant-a
- istiod-b in istio-system-b, revision: tenant-b
- ZTunnel pointing at istiod-tenant-a (xdsAddress + caAddress)

**Problem:** ZTunnel only supports a single xdsAddress and caAddress.
Pointing ztunnel at istiod-a meant tenant-b workloads were invisible to ztunnel
(ConnectedEndpoints:0 on istiod-b). Toggling ztunnel between istiods broke
whichever tenant was not currently pointed at.

**Lesson:** Multiple istiod instances cannot serve a single shared ztunnel.
The per-tenant istiod model only works with sidecar mode, not ambient.

---

## Files in this directory

| File | Kind | Purpose |
|---|---|---|
| istio-namespace.yaml | Namespace | istio-system — shared control plane namespace |
| istio.yaml | Istio | Single istiod, revision: default, watches all tenant namespaces |

---

## Namespace labels required

All namespaces that istiod must watch need to match a discoverySelector:

| Namespace | Label required |
|---|---|
| istio-system | istio-discovery=enabled |
| ztunnel | istio-discovery=enabled |
| istio-cni | istio-discovery=enabled |
| bookinfo-a | mesh=tenant-a |
| bookinfo-ingress-a | mesh=tenant-a |
| bookinfo-b | mesh=tenant-b |
| bookinfo-ingress-b | mesh=tenant-b |

**Critical lesson:** When migrating from per-tenant istiods, old namespaces
carry stale labels (istio-discovery-a, istio-discovery-b). These must be
replaced with the canonical `istio-discovery=enabled` label or istiod will
not trust ztunnel pods in those namespaces, causing TLS handshake failures:

```
tls: bad certificate
XDS client connection error: invalid peer certificate: BadSignature
```

Fix:
```bash
oc label namespace ztunnel istio-discovery-a- istio-discovery=enabled
oc label namespace istio-cni istio-discovery-a- istio-discovery-b- istio-discovery=enabled
```

---

## Workload namespace labels — no istio.io/rev needed

With a single shared istiod (revision: default), workload namespaces do NOT
need `istio.io/rev`. The Gateway API controller uses revision "default" automatically.

```yaml
# WRONG — tenant-specific rev label, breaks when istiod is removed
labels:
  istio.io/rev: tenant-a

# CORRECT — no rev label needed with single shared istiod
labels:
  mesh: tenant-a
  istio.io/dataplane-mode: ambient
  istio.io/use-waypoint: waypoint
```

---

## Apply order

```bash
# 1. Create namespace first
oc apply -f istio-namespace.yaml

# 2. Create Istio CR
oc apply -f istio.yaml

# 3. Verify
oc get istio default
# NAME      NAMESPACE     STATUS    VERSION
# default   istio-system  Healthy   v1.27.5

# 4. Update shared namespace labels if migrating from per-tenant istiods
oc label namespace ztunnel istio-discovery-a- istio-discovery=enabled --overwrite
oc label namespace istio-cni istio-discovery-a- istio-discovery-b- istio-discovery=enabled --overwrite
```
