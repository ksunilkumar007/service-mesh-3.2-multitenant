# service-mesh-3.2-multitenancy/

## What this repo does

Deploys OSSM 3.2 ambient mode with dedicated node pools per tenant on a
multi-node AWS OpenShift cluster (spoke1). Each tenant gets a completely
isolated control plane, data plane, ingress gateway, and policy stack.

This repo is intentionally kept separate from service-mesh-3.2/ (the SNO
single-tenant lab). Nothing here touches or depends on that folder.
Read service-mesh-3.2/mesh/ambient/README.md first to understand the
ambient mode fundamentals before working through this repo.

---

## Lab environment

```
Cluster:      spoke1 (multi-node, platform: AWS)
OCP:          4.20
Base DNS:     sandbox2841.opentlc.com
Operator:     servicemeshoperator3.v3.2.2
Istio:        v1.27.5_ossm (Red Hat build)

Worker nodes:
  tenant-a pool:  ip-10-0-0-5, ip-10-0-19-190       (mesh=tenant-a:NoSchedule)
  tenant-b pool:  ip-10-0-19-203, ip-10-0-47-253     (mesh=tenant-b:NoSchedule)
  infra node:     ip-10-0-57-92                       (mesh=infra, no taint)
```

---

## Folder structure

```
service-mesh-3.2-multitenancy/
│
├── README.md                               <- this file
├── validate.sh                             <- end-to-end health checks
│
├── operator/                               <- same operators as SNO, reused as-is
│   ├── sail-operator.yaml
│   ├── kiali-operator.yaml
│   ├── otel-operator.yaml
│   ├── tempo-operator.yaml
│   └── cluster-observability-operator.yaml
│
├── node-pools/                             <- label + taint scripts (already applied)
│   ├── label-taint-tenant-a.sh
│   ├── label-taint-tenant-b.sh
│   └── label-infra.sh
│
├── shared/
│   └── cni/
│       └── istio-cni.yaml                  <- IstioCNI DaemonSet, runs on ALL nodes
│
├── tenant-a/
│   ├── control-plane/
│   │   ├── namespace-istio-system-a.yaml   <- istio-system-a namespace
│   │   ├── namespace-ztunnel-a.yaml        <- ztunnel-a namespace
│   │   ├── istiod-a.yaml                   <- Istio CR scoped to tenant-a
│   │   └── ztunnel-a.yaml                  <- ZTunnel CR pinned to tenant-a nodes
│   ├── namespaces/
│   │   ├── bookinfo-a.yaml                 <- app namespace + ambient labels
│   │   └── bookinfo-ingress-a.yaml         <- ingress gateway namespace
│   ├── gateways/
│   │   ├── bookinfo-gateway-a.yaml         <- AWS LoadBalancer ingress gateway
│   │   ├── bookinfo-httproute-a.yaml       <- routes /productpage to bookinfo-a
│   │   ├── referencegrant-a.yaml           <- cross-ns Waypoint reference
│   │   └── waypoint-a.yaml                 <- L7 Waypoint for bookinfo-a
│   ├── policy/
│   │   ├── peerauth-meshwide-a.yaml        <- STRICT mTLS for istio-system-a
│   │   ├── peerauth-bookinfo-a.yaml        <- STRICT mTLS for bookinfo-a
│   │   ├── authpolicy-ingress-a.yaml       <- GET-only at ingress gateway
│   │   ├── authpolicy-productpage-a.yaml   <- L7 access control via Waypoint
│   │   └── authpolicy-deny-cross-pool.yaml <- DENY all traffic from tenant-b
│   └── observability/
│       ├── tracing-namespace-a.yaml
│       ├── tempo-bucket-a.yaml
│       ├── tempostack-a.yaml
│       ├── otel-collector-a.yaml
│       └── servicemonitor-a.yaml
│
├── tenant-b/                               <- mirrors tenant-a, -b suffix throughout
│   ├── control-plane/
│   │   ├── namespace-istio-system-b.yaml
│   │   ├── namespace-ztunnel-b.yaml
│   │   ├── istiod-b.yaml
│   │   └── ztunnel-b.yaml
│   ├── namespaces/
│   │   ├── bookinfo-b.yaml
│   │   └── bookinfo-ingress-b.yaml
│   ├── gateways/
│   │   ├── bookinfo-gateway-b.yaml
│   │   ├── bookinfo-httproute-b.yaml
│   │   ├── referencegrant-b.yaml
│   │   └── waypoint-b.yaml
│   ├── policy/
│   │   ├── peerauth-meshwide-b.yaml
│   │   ├── peerauth-bookinfo-b.yaml
│   │   ├── authpolicy-ingress-b.yaml
│   │   ├── authpolicy-productpage-b.yaml
│   │   └── authpolicy-deny-cross-pool.yaml
│   └── observability/
│       ├── tracing-namespace-b.yaml
│       ├── tempo-bucket-b.yaml
│       ├── tempostack-b.yaml
│       ├── otel-collector-b.yaml
│       └── servicemonitor-b.yaml
│
└── kiali/
    ├── kiali.yaml                          <- single shared Kiali instance
    ├── kiali-rbac-tenant-a.yaml            <- RBAC scoped to tenant-a namespaces
    └── kiali-rbac-tenant-b.yaml            <- RBAC scoped to tenant-b namespaces
```

---

## Apply order (overview)

Each block has its own README with detailed steps, lessons learned,
and verification commands. Follow them in this order:

```
1.  node-pools/          Label and taint worker nodes       DONE
2.  operator/            Install operators                  (reuse from SNO if already installed)
3.  shared/cni/          Deploy shared IstioCNI             README: shared/cni/README.md
4.  tenant-a/control-plane/   istiod-a + ztunnel-a         README: tenant-a/control-plane/README.md
5.  tenant-a/namespaces/      bookinfo-a namespaces         README: tenant-a/namespaces/README.md
6.  tenant-a/gateways/        waypoint + ingress            README: tenant-a/gateways/README.md
7.  tenant-a/policy/          mTLS + authz policies         README: tenant-a/policy/README.md
8.  tenant-a/observability/   Tempo + OTEL                  README: tenant-a/observability/README.md
    -- repeat 4-8 for tenant-b --
9.  kiali/               Shared Kiali + per-tenant RBAC     README: kiali/README.md
```

---

## Key differences from service-mesh-3.2/ (SNO)

### What is reused unchanged
- All 5 operators in operator/ — identical to SNO, apply once
- IstioCNI — same CR, runs cluster-wide on all nodes
- bookinfo app manifest — same upstream YAML, different namespace

### What is patched from SNO source
Every patched file has the source noted in its block README.

| SNO file | Multitenancy file | Key changes |
|---|---|---|
| mesh/ambient/istio.yaml | tenant-a/control-plane/istiod-a.yaml | name, namespace, trustedZtunnelNamespace, discoverySelectors |
| mesh/ambient/ztunnel.yaml | tenant-a/control-plane/ztunnel-a.yaml | namespace, nodeSelector, tolerations |
| mesh/ambient/waypoint.yaml | tenant-a/gateways/waypoint-a.yaml | namespace, name |
| mesh/ambient/peerauth-meshwide.yaml | tenant-a/policy/peerauth-meshwide-a.yaml | namespace |
| mesh/ambient/peerauth-bookinfo.yaml | tenant-a/policy/peerauth-bookinfo-a.yaml | namespace |
| mesh/ambient/authorizationpolicy.yaml | tenant-a/policy/authpolicy-productpage-a.yaml | namespace, principals |
| gateways/ingress/bookinfo-gateway.yaml | tenant-a/gateways/bookinfo-gateway-a.yaml | name, namespace, AWS LB |
| gateways/ingress/bookinfo-httproute.yaml | tenant-a/gateways/bookinfo-httproute-a.yaml | namespace, hostname |
| gateways/ingress/referencegrant.yaml | tenant-a/gateways/referencegrant-a.yaml | namespace, names |
| gateways/ingress/authpolicy.yaml | tenant-a/policy/authpolicy-ingress-a.yaml | namespace, gateway name |

### What is new (no SNO equivalent)
- node-pools/ scripts — multi-node only
- authpolicy-deny-cross-pool.yaml — DENY cross-tenant traffic
- Per-tenant observability stack

### What is dropped from SNO
- bookinfo-route.yaml — OCP Route not needed on AWS
  AWS provisions an NLB automatically via type=LoadBalancer
  No ClusterIP annotation required
