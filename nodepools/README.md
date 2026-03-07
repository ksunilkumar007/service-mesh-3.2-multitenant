# node-pools/

## What this block does

Labels and taints the worker nodes to create dedicated node pools per tenant.
This must be done before deploying any mesh components — istiod
discoverySelectors and ztunnel nodeSelectors depend on these labels
being present at scheduling time.

All findings are from actual lab observations on spoke1.

---

## Lab environment

```
Cluster:   spoke1 (multi-node, platform: AWS)
OCP:       4.20
Workers:   5 x m5.xlarge in us-east-1a
```

---

## Files in this directory

| File | What it does |
|---|---|
| label-taint-tenant-a.sh | Labels and taints worker-0 and worker-1 for tenant-a |
| label-taint-tenant-b.sh | Labels and taints worker-2 and worker-3 for tenant-b |
| label-infra.sh | Labels the infra node — no taint, general workloads allowed |

---

## Node pool design

5 worker nodes split across 3 roles:

```
tenant-a pool  →  2 nodes  →  mesh control plane + bookinfo-a workloads
tenant-b pool  →  2 nodes  →  mesh control plane + bookinfo-b workloads
infra          →  1 node   →  shared/unassigned workloads, no tenant taint
```

The infra node has no taint — any workload can schedule there.
Tenant-a and tenant-b nodes have NoSchedule taints — only workloads
with the matching toleration will be scheduled on them.

---

## Taint effect — why NoSchedule

Three taint effects exist in Kubernetes:

| Effect | Behaviour |
|---|---|
| NoSchedule | New pods without toleration will not be scheduled on the node. Existing pods are not evicted. |
| PreferNoSchedule | Scheduler avoids the node but does not hard-block. Not suitable for tenant isolation. |
| NoExecute | New pods blocked AND existing pods without toleration are evicted. Too aggressive for initial setup. |

NoSchedule was chosen because:
- Hard isolation — tenant-b workloads cannot land on tenant-a nodes
- Non-destructive — existing pods already running are not evicted
- Explicit — workloads that need to run on a tenant node must declare a toleration

---

## Node assignment

| Node | IP | Pool | Label | Taint |
|---|---|---|---|---|
| worker-0 | ip-10-0-0-5.ec2.internal | tenant-a | mesh=tenant-a | mesh=tenant-a:NoSchedule |
| worker-1 | ip-10-0-19-190.ec2.internal | tenant-a | mesh=tenant-a | mesh=tenant-a:NoSchedule |
| worker-2 | ip-10-0-19-203.ec2.internal | tenant-b | mesh=tenant-b | mesh=tenant-b:NoSchedule |
| worker-3 | ip-10-0-47-253.ec2.internal | tenant-b | mesh=tenant-b | mesh=tenant-b:NoSchedule |
| worker-4 | ip-10-0-57-92.ec2.internal | infra | mesh=infra | none |

---

## Commands applied

### Tenant A

```bash
# Labels
oc label node ip-10-0-0-5.ec2.internal mesh=tenant-a
oc label node ip-10-0-19-190.ec2.internal mesh=tenant-a

# Taints
oc adm taint node ip-10-0-0-5.ec2.internal mesh=tenant-a:NoSchedule
oc adm taint node ip-10-0-19-190.ec2.internal mesh=tenant-a:NoSchedule
```

### Tenant B

```bash
# Labels
oc label node ip-10-0-19-203.ec2.internal mesh=tenant-b
oc label node ip-10-0-47-253.ec2.internal mesh=tenant-b

# Taints
oc adm taint node ip-10-0-19-203.ec2.internal mesh=tenant-b:NoSchedule
oc adm taint node ip-10-0-47-253.ec2.internal mesh=tenant-b:NoSchedule
```

### Infra

```bash
# Label only — no taint
oc label node ip-10-0-57-92.ec2.internal mesh=infra
```

---

## Verified output

```bash
oc get nodes -o custom-columns=\
NAME:.metadata.name,\
MESH-LABEL:.metadata.labels.mesh,\
TAINTS:.spec.taints \
--selector='node-role.kubernetes.io/worker'
```

```
NAME                            MESH-LABEL   TAINTS
ip-10-0-0-5.ec2.internal        tenant-a     [map[effect:NoSchedule key:mesh value:tenant-a]]
ip-10-0-19-190.ec2.internal     tenant-a     [map[effect:NoSchedule key:mesh value:tenant-a]]
ip-10-0-19-203.ec2.internal     tenant-b     [map[effect:NoSchedule key:mesh value:tenant-b]]
ip-10-0-47-253.ec2.internal     tenant-b     [map[effect:NoSchedule key:mesh value:tenant-b]]
ip-10-0-57-92.ec2.internal      infra        <none>
```

---

## How these labels and taints are consumed downstream

### ztunnel nodeSelector + tolerations (tenant-a/control-plane/ztunnel-a.yaml)

```yaml
values:
  nodeSelector:
    mesh: tenant-a        # schedule ztunnel-a only on tenant-a nodes
  tolerations:
  - key: mesh
    value: tenant-a
    effect: NoSchedule    # allow ztunnel-a to run despite the taint
```

Without the toleration, ztunnel-a pods would be blocked by the NoSchedule
taint and the DaemonSet would show 0/2 pods on tenant-a nodes.

### istiod discoverySelectors (tenant-a/control-plane/istiod-a.yaml)

```yaml
meshConfig:
  discoverySelectors:
  - matchLabels:
      mesh: tenant-a      # istiod-a only watches namespaces labelled mesh=tenant-a
```

istiod-b uses mesh=tenant-b. Neither istiod can see the other tenant's
namespaces, Services, or Endpoints.

### Namespace labels (tenant-a/namespaces/*.yaml)

Every tenant-a namespace carries:
```yaml
labels:
  mesh: tenant-a          # makes it visible to istiod-a discoverySelectors
  istio.io/dataplane-mode: ambient  # enrolls pods in ambient data plane
```

---

## How to undo a taint (if needed)

Add a `-` at the end of the taint value to remove it:

```bash
oc adm taint node ip-10-0-0-5.ec2.internal mesh=tenant-a:NoSchedule-
```

How to remove a label:
```bash
oc label node ip-10-0-0-5.ec2.internal mesh-
```

---

## Status

```
DONE — labels and taints applied and verified on spoke1.
These scripts are kept here for reference and for reprovisioning
if the cluster is rebuilt.
```

---

## What to do next

```
operator/      Verify operators are Succeeded (already done on spoke1)
shared/cni/    Deploy shared IstioCNI DaemonSet
```
