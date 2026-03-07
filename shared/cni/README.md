# shared/cni/

## What this block does

Deploys the Istio CNI DaemonSet on every node in the cluster.
This is a shared component — one instance serves all tenants.
It is the first mesh component deployed after the operators.

All findings are from actual lab observations on spoke1.

---

## Lab environment

```
Cluster:   spoke1 (multi-node, platform: AWS)
OCP:       4.20
Nodes:     8 total (3 masters + 5 workers)
           CNI pod runs on ALL 8 nodes
Operator:  servicemeshoperator3.v3.2.2
Source:    service-mesh-3.2/mesh/ambient/istio-cni.yaml (YAML unchanged)
```

---

## Files in this directory

| File | Kind | API | What it deploys |
|---|---|---|---|
| istio-cni-namespace.yaml | Namespace | v1 | istio-cni namespace with dual discovery labels |
| istio-cni.yaml | IstioCNI | sailoperator.io/v1 | CNI DaemonSet on all nodes |

---

## Why IstioCNI is in shared/ and not per-tenant

IstioCNI is a cluster-scoped resource. Only one CR named `default`
can exist per cluster. The DaemonSet runs one pod per node across
all nodes regardless of tenant labels or taints.

The CNI plugin has no concept of tenants. Its only job is:
- Watch for pods in namespaces labelled `istio.io/dataplane-mode=ambient`
- Insert iptables rules into those pod network namespaces at creation time
- Redirect pod traffic to the local ztunnel on port 15008 (HBONE)

Tenant isolation happens at the layers above CNI:

```
CNI         → inserts iptables rules         (shared, no tenant awareness)
ztunnel     → enforces SPIFFE identity       (per-tenant, pinned by nodeSelector)
istiod      → distributes xDS policy         (per-tenant, scoped by discoverySelectors)
Waypoint    → enforces L7 AuthorizationPolicy (per-tenant, per-namespace)
```

---

## What changed from SNO

### istio-cni.yaml — nothing

The YAML is identical to service-mesh-3.2/mesh/ambient/istio-cni.yaml.
Every spec field is the same value.

| Field | SNO value | Multi-tenant value |
|---|---|---|
| name | default | default |
| namespace | istio-cni | istio-cni |
| profile | ambient | ambient |
| reconcileIptablesOnStartup | true | true |

### istio-cni-namespace.yaml — new file, important lesson

On SNO the istio-cni namespace was created with:
  oc label namespace istio-cni istio-discovery=enabled

On multi-tenant both istiod-a and istiod-b need to discover istio-cni.
Each istiod uses its own discoverySelector label key to avoid the
duplicate YAML key problem:

```
WRONG — YAML duplicate key, tenant-a silently overwritten:
  labels:
    mesh: tenant-a
    mesh: tenant-b    <- overwrites tenant-a, only tenant-b wins

CORRECT — separate label keys per tenant:
  labels:
    istio-discovery-a: enabled    <- istiod-a discoverySelector matches this
    istio-discovery-b: enabled    <- istiod-b discoverySelector matches this
```

This label pattern is used on all shared control plane namespaces.
Workload namespaces (bookinfo-a, bookinfo-b) are owned by exactly
one tenant so they use mesh=tenant-a or mesh=tenant-b without conflict.

---

## Pre-flight — namespace must exist before IstioCNI CR

The Sail Operator reconciler validates the target namespace exists
before deploying the DaemonSet. Applying istio-cni.yaml before the
namespace exists causes:

```
error reconciling resource: validation error: namespace "istio-cni" doesn't exist
```

Always apply istio-cni-namespace.yaml first.

---

## Apply order

```bash
# 1. Namespace first
oc apply -f istio-cni-namespace.yaml

# Confirm namespace and labels
oc get namespace istio-cni --show-labels
# istio-discovery-a=enabled,istio-discovery-b=enabled

# 2. IstioCNI CR
oc apply -f istio-cni.yaml

# Watch until Healthy
oc get istiocni default -w
# Expected: STATUS=Healthy  VERSION=v1.27.5
```

---

## Verified output

```
NAME      NAMESPACE   PROFILE   READY   STATUS    VERSION   AGE
default   istio-cni             True    Healthy   v1.27.5   7s
```

```bash
oc get pods -n istio-cni -o wide
```

```
NAME                   READY   STATUS    NODE
istio-cni-node-24mmq   1/1     Running   ip-10-0-26-236.ec2.internal   (master-1)
istio-cni-node-85869   1/1     Running   ip-10-0-19-190.ec2.internal   (tenant-a worker-1)
istio-cni-node-86pbp   1/1     Running   ip-10-0-35-118.ec2.internal   (master-2)
istio-cni-node-bm9tw   1/1     Running   ip-10-0-17-209.ec2.internal   (master-0)
istio-cni-node-dg5m7   1/1     Running   ip-10-0-57-92.ec2.internal    (infra)
istio-cni-node-dsxkq   1/1     Running   ip-10-0-19-203.ec2.internal   (tenant-b worker-2)
istio-cni-node-gn6xc   1/1     Running   ip-10-0-47-253.ec2.internal   (tenant-b worker-3)
istio-cni-node-hfhd4   1/1     Running   ip-10-0-0-5.ec2.internal      (tenant-a worker-0)
```

8/8 nodes covered — all Running. ✅

---

## Multi-node behaviour vs SNO

On SNO there is one CNI pod on one node. A CNI restart affects all
enrolled pods simultaneously.

On multi-node one CNI pod runs per node independently:
- A CNI restart on a tenant-a node does NOT affect tenant-b pods
- Failure domain is per-node, not per-cluster
- `reconcileIptablesOnStartup: true` still required — re-inserts
  iptables rules on each node restart without requiring pod restarts

---

## What to do next

```
tenant-a/control-plane/   Deploy namespace-istio-system-a, istiod-a, ztunnel-a
```
