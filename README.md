# service-mesh-3.2-multitenancy/

## What this repo does

Deploys OSSM 3.2 ambient mode with dedicated node pools per tenant on a
multi-node AWS OpenShift cluster (spoke1). Two tenants share a single
control plane and data plane. Isolation is enforced via node taints,
per-tenant waypoints, and AuthorizationPolicy.

This repo is intentionally kept separate from service-mesh-3.2/ (the SNO
single-tenant lab). Nothing here touches or depends on that folder.
Read service-mesh-3.2/mesh/ambient/README.md first to understand the
ambient mode fundamentals before working through this repo.

---

## Architecture Decision — Single Shared Control Plane

**True multi-tenant ambient mode with separate istiod/ztunnel per tenant
is NOT supported in Istio 1.27.5.**

One cluster = one ztunnel DaemonSet = one ambient mesh.

Per-tenant istiod was attempted and abandoned:
- ztunnel only supports a single `xdsAddress` + `caAddress`
- Switching breaks whichever tenant ztunnel is not pointed at
- `ConnectedEndpoints: 0` on whichever istiod ztunnel was not connected to

**Final architecture:**
```
Shared:           istiod (default, istio-system) → ztunnel DaemonSet (all nodes)
Tenant isolation: node taints + per-tenant waypoints + AuthorizationPolicy
Observability:    shared Tempo + OTel + Kiali with per-tenant RBAC
```

---

## Lab environment

```
Cluster:      spoke1 (multi-node, platform: AWS)
OCP:          4.20
Base DNS:     sandbox2841.opentlc.com
Operator:     servicemeshoperator3.v3.2.2
Istio:        v1.27.5_ossm (Red Hat build)
OTel:         v0.144.0

Worker nodes:
  tenant-a pool:  ip-10-0-0-5, ip-10-0-19-190       (mesh=tenant-a:NoSchedule)
  tenant-b pool:  ip-10-0-19-203, ip-10-0-47-253     (mesh=tenant-b:NoSchedule)
  infra node:     ip-10-0-57-92                       (no taint)
```

---

## Node pools

Node labelling and tainting was applied manually before this repo was used.
Reference scripts kept in `node-pools/` for documentation:

```bash
# tenant-a nodes
oc label node ip-10-0-0-5 ip-10-0-19-190 node-role.kubernetes.io/tenant-a=''
oc taint node ip-10-0-0-5 ip-10-0-19-190 mesh=tenant-a:NoSchedule

# tenant-b nodes
oc label node ip-10-0-19-203 ip-10-0-47-253 node-role.kubernetes.io/tenant-b=''
oc taint node ip-10-0-19-203 ip-10-0-47-253 mesh=tenant-b:NoSchedule
```

## Operators

Reused unchanged from `service-mesh-3.2/operator/`. Apply once per cluster:

```
sail-operator.yaml
kiali-operator.yaml
otel-operator.yaml
tempo-operator.yaml
cluster-observability-operator.yaml
```

---

## Folder structure

```
service-mesh-3.2-multitenant/
│
├── README.md                                    ← this file
├── validate.sh                                  ← end-to-end health checks (126 tests)
│
├── shared/
│   ├── cni/
│   │   ├── istio-cni-namespace.yaml             ← istio-cni namespace
│   │   └── istio-cni.yaml                       ← IstioCNI DaemonSet, all nodes
│   │
│   ├── control-plane/
│   │   ├── istio-namespace.yaml                 ← istio-system namespace
│   │   └── istio.yaml                           ← single shared istiod
│   │                                               profile: ambient (REQUIRED)
│   │                                               defaultProviders.tracing (REQUIRED)
│   │                                               defaultProviders.metrics (REQUIRED)
│   │                                               extensionProviders: otel-tracing
│   │
│   ├── ztunnel/
│   │   ├── ztunnel-namespace.yaml               ← ztunnel namespace
│   │   └── ztunnel.yaml                         ← ZTunnel DaemonSet, all nodes
│   │
│   ├── policy/
│   │   └── peerauth-meshwide.yaml               ← STRICT mTLS mesh-wide
│   │
│   ├── observability/
│   │   ├── tracing-namespace.yaml               ← NO ambient mode (readiness probe fix)
│   │   ├── tempo-bucket-aws.sh                  ← creates S3 bucket + secret (AWS)
│   │   ├── tempo-bucket-odf.yaml                ← OBC for ODF/NooBaa clusters
│   │   ├── tempostack.yaml                      ← shared Tempo, tenant-a + tenant-b
│   │   ├── tempostack-odf.yaml                  ← ODF variant (TLS enabled)
│   │   ├── tempo-rbac.yaml                      ← per-tenant Tempo write/read RBAC
│   │   ├── otel-collector.yaml                  ← shared OTel, two pipelines
│   │   ├── istio-telemetry.yaml                 ← mesh-wide Telemetry CR
│   │   ├── uiplugin.yaml                        ← OCP distributed tracing UI
│   │   └── monitors/
│   │       ├── prometheus-rbac.yaml             ← REQUIRED on multi-node OCP
│   │       ├── istiod-monitor.yaml              ← istiod Service + ServiceMonitor
│   │       ├── ztunnel-monitor.yaml             ← ztunnel Service + ServiceMonitor
│   │       └── waypoint-monitor.yaml            ← waypoint PodMonitor (both tenants)
│   │
│   ├── kiali/
│   │   ├── kiali-rbac.yaml                      ← Kiali SA access to all namespaces
│   │   └── kiali.yaml                           ← single shared Kiali instance
│   │
│   └── monitoring/
│       └── cluster-monitoring-config.yaml       ← enableUserWorkload + thanosQuerier
│
├── tenant-a/
│   ├── namespaces/
│   │   ├── bookinfo-a.yaml                      ← mesh=tenant-a, ambient, use-waypoint
│   │   ├── bookinfo-ingress-a.yaml              ← mesh=tenant-a, ambient
│   │   └── bookinfo-patch-a.sh                  ← deploys bookinfo app
│   ├── gateways/
│   │   ├── waypoint-a.yaml                      ← L7 waypoint for bookinfo-a
│   │   ├── waypoint-configmap-a.yaml            ← pins waypoint to tenant-a nodes
│   │   ├── bookinfo-gateway-a.yaml              ← AWS NLB ingress gateway
│   │   ├── bookinfo-gateway-configmap-a.yaml    ← pins gateway to tenant-a nodes
│   │   ├── bookinfo-httproute-a.yaml            ← routes /productpage
│   │   ├── referencegrant-a.yaml                ← cross-ns gateway reference
│   │   └── telemetry-a.yaml                     ← waypoint tracing (targetRef)
│   └── policy/
│       ├── peerauth-bookinfo-a.yaml             ← STRICT mTLS for bookinfo-a
│       ├── authpolicy-ingress-a.yaml            ← GET-only at ingress gateway
│       └── authpolicy-productpage-a.yaml        ← L7 access via waypoint
│
└── tenant-b/                                    ← mirrors tenant-a with -b suffix
    ├── namespaces/
    │   ├── bookinfo-b.yaml
    │   ├── bookinfo-ingress-b.yaml
    │   └── bookinfo-patch-b.sh
    ├── gateways/
    │   ├── waypoint-b.yaml
    │   ├── waypoint-configmap-b.yaml
    │   ├── bookinfo-gateway-b.yaml
    │   ├── bookinfo-gateway-configmap-b.yaml
    │   ├── bookinfo-httproute-b.yaml
    │   ├── referencegrant-b.yaml
    │   └── telemetry-b.yaml
    └── policy/
        ├── peerauth-bookinfo-b.yaml
        ├── authpolicy-ingress-b.yaml
        └── authpolicy-productpage-b.yaml
```

---

## Apply order

```bash
# 1. Shared CNI
oc apply -f shared/cni/istio-cni-namespace.yaml
oc apply -f shared/cni/istio-cni.yaml

# 2. Shared control plane
oc apply -f shared/control-plane/istio-namespace.yaml
oc apply -f shared/control-plane/istio.yaml

# 3. ZTunnel
oc apply -f shared/ztunnel/ztunnel-namespace.yaml
oc apply -f shared/ztunnel/ztunnel.yaml

# 4. Mesh-wide policy
oc apply -f shared/policy/peerauth-meshwide.yaml

# 5. Tenant namespaces
oc apply -f tenant-a/namespaces/bookinfo-a.yaml
oc apply -f tenant-a/namespaces/bookinfo-ingress-a.yaml
oc apply -f tenant-b/namespaces/bookinfo-b.yaml
oc apply -f tenant-b/namespaces/bookinfo-ingress-b.yaml

# 6. Bookinfo apps
bash tenant-a/namespaces/bookinfo-patch-a.sh
bash tenant-b/namespaces/bookinfo-patch-b.sh

# 7. Gateways + waypoints
oc apply -f tenant-a/gateways/
oc apply -f tenant-b/gateways/

# 8. Policies
oc apply -f tenant-a/policy/
oc apply -f tenant-b/policy/

# 9. Observability — tracing
oc apply -f shared/observability/tracing-namespace.yaml
bash shared/observability/tempo-bucket-aws.sh        # AWS only
# oc apply -f shared/observability/tempo-bucket-odf.yaml  # ODF only
oc apply -f shared/observability/tempo-rbac.yaml
oc apply -f shared/observability/tempostack.yaml
oc apply -f shared/observability/otel-collector.yaml
oc apply -f shared/observability/istio-telemetry.yaml
oc apply -f shared/observability/uiplugin.yaml

# 10. Observability — monitors
oc apply -f shared/observability/monitors/prometheus-rbac.yaml
oc apply -f shared/observability/monitors/istiod-monitor.yaml
oc apply -f shared/observability/monitors/ztunnel-monitor.yaml
oc apply -f shared/observability/monitors/waypoint-monitor.yaml

# 11. Kiali
oc apply -f shared/kiali/kiali-rbac.yaml
oc apply -f shared/kiali/kiali.yaml

# 12. Cluster monitoring
oc apply -f shared/monitoring/cluster-monitoring-config.yaml
```

---

## Namespace labels (required)

| Namespace | Labels |
|---|---|
| istio-system, istio-cni, ztunnel, tracing | `istio-discovery=enabled` `openshift.io/user-monitoring=true` |
| bookinfo-a, bookinfo-ingress-a | `mesh=tenant-a` `istio-discovery=enabled` `istio.io/dataplane-mode=ambient` `openshift.io/user-monitoring=true` |
| bookinfo-b, bookinfo-ingress-b | `mesh=tenant-b` `istio-discovery=enabled` `istio.io/dataplane-mode=ambient` `openshift.io/user-monitoring=true` |
| bookinfo-a, bookinfo-b only | `istio.io/use-waypoint=waypoint` |

---

## Key differences from service-mesh-3.2/ (SNO)

| Topic | SNO | Multi-tenant AWS |
|---|---|---|
| istiod | single, default | single shared (per-tenant NOT supported) |
| ztunnel | single | single shared, tolerates all taints |
| Storage | NooBaa OBC | AWS S3 native (`tempo-bucket-aws.sh`) |
| Gateway Service | ClusterIP + OCP Route | LoadBalancer (AWS NLB auto-provisioned) |
| Prometheus scraping | works out of the box | needs `prometheus-rbac.yaml` per namespace |
| OCP Observe targets | shows automatically | needs `openshift.io/user-monitoring=true` label |
| Thanos federation | not needed | needs `thanosQuerier.tolerations` in cluster-monitoring-config |
| Waypoint tracing | mesh-wide Telemetry CR | `targetRef` Telemetry CR per gateway namespace |
| Tempo TLS | `caName: openshift-service-ca.crt` | `tls.enabled: false` (AWS S3 public CA) |

---

## Hard-won lessons learned

### 1 — profile: ambient is mandatory in Istio CR
If `profile: ambient` is missing or dropped (e.g. by applying inline
manifest), `PILOT_ENABLE_AMBIENT=true` is not set and ztunnel gets:
```
"ztunnel requires PILOT_ENABLE_AMBIENT=true"
```
Always set `spec.profile: ambient` explicitly in the Istio CR.

### 2 — defaultProviders.tracing required for waypoint tracing
The ambient profile sets `defaultProviders.metrics: prometheus` automatically
but does NOT set `defaultProviders.tracing`. Without it, waypoints ignore
Telemetry CRs for tracing entirely. Must add explicitly:
```yaml
meshConfig:
  defaultProviders:
    tracing:
    - otel-tracing
```

### 3 — Telemetry CR needs targetRef for waypoints
A mesh-wide Telemetry CR in `istio-system` does NOT activate tracing on
waypoint proxies in ambient mode. Must use `targetRef` pointing to the
Gateway CR in each gateway namespace.

### 4 — OTel filter processor drops all Istio spans
Istio's OTLP exporter does NOT include `k8s.namespace.name` in resource
attributes by default. Any filter on that attribute drops all spans.
Use Tempo per-tenant RBAC for isolation instead of OTel filtering.

### 5 — routing processor removed in otelcol v0.144.0
Use separate pipelines with `filter` processor or no filter at all.

### 6 — tracing namespace must NOT be in ambient mode
Tempo readiness probes (kubelet → pod) fail when ztunnel intercepts
pod-local traffic. Remove `istio.io/dataplane-mode=ambient` from
the tracing namespace.

### 7 — ztunnel BadSignature after istiod restart
After replacing istiod, ztunnel pods carry stale certs:
```
invalid peer certificate: BadSignature
```
Must restart ztunnel DaemonSet AND istiod after any istiod replacement.

### 8 — Gateway node pinning via parametersRef ConfigMap
`spec.infrastructure.labels` sets pod labels only, not nodeSelector.
`scheduling.istio.io/*` annotations not effective in Istio 1.27.5.
Only working method: `spec.infrastructure.parametersRef` → ConfigMap
with `deployment` key containing nodeSelector + tolerations.

### 9 — Prometheus scraping on multi-node OCP
`prometheus-user-workload` SA needs explicit RoleBindings in every
namespace it scrapes. Without this, ServiceMonitors are silently ignored.
Not needed on SNO due to broader default permissions.

### 10 — OCP console Observe → Targets shows User: 0
Requires both:
- `openshift.io/user-monitoring: "true"` label on each namespace
- `thanosQuerier.tolerations` in `cluster-monitoring-config` so
  Thanos Querier pods can schedule on tainted nodes

### 11 — ztunnel metrics use istio_* prefix not ztunnel_*
In ambient mode all metrics from ztunnel use `istio_*` and
`workload_manager_*` prefixes. Searching `ztunnel_*` returns nothing.
Filter by instance label: `{instance="<ztunnel-pod-ip>:15020"}`

### 12 — No sidecar metrics in ambient mode
App pods have no sidecar in ambient mode — port 15020 does not exist
on app pods. All L7 metrics come from the Waypoint (15090/15020),
all L4 metrics from ztunnel (15020).

---

## Validation

```bash
./validate.sh
# Expected: PASS: 126, WARN: 0-3, FAIL: 0
```

Warnings on OTel span counts are expected if no traffic has been
generated recently — run curl against both NLBs first.
