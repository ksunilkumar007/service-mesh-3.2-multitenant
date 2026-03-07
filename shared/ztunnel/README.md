# shared/ztunnel/

## What this block does

Deploys the single cluster-wide ZTunnel CR. Despite serving multiple tenants,
only one ZTunnel CR named "default" can exist per cluster — enforced by the
Sail Operator. Tenant isolation is achieved through nodeSelector, tolerations,
and xdsAddress inside the CR — not through separate CRs.

All findings are from actual lab observations on spoke1.

---

## Lab environment

```
Cluster:   spoke1 (multi-node, platform: AWS)
OCP:       4.20
Operator:  servicemeshoperator3.v3.2.2
Source:    service-mesh-3.2/mesh/ambient/ztunnel.yaml (patched)
```

---

## Files in this directory

| File | Kind | API | What it deploys |
|---|---|---|---|
| ztunnel-namespace.yaml | Namespace | v1 | ztunnel-a namespace with istio-discovery-a=enabled |
| ztunnel.yaml | ZTunnel | sailoperator.io/v1 | Single cluster-wide ztunnel DaemonSet |

---

## Why ZTunnel is in shared/ and not tenant-a/

The Sail Operator enforces that only ONE ZTunnel CR named "default"
can exist per cluster. Attempting to create a second CR with any
other name fails immediately:

```
The ZTunnel "tenant-a" is invalid: metadata.name must be 'default'
```

This is different from IstioCNI (also one per cluster) and Istio
(one per tenant — revision names allow multiple).

ZTunnel tenant isolation is achieved through:
- spec.namespace        → which namespace the DaemonSet pods run in
- values.ztunnel.nodeSelector   → which nodes the pods schedule on
- values.ztunnel.tolerations    → tolerate tenant node taints
- values.ztunnel.xdsAddress     → which istiod the pods connect to

The CR is shared. The configuration inside it is tenant-specific.

---

## Current configuration — tenant-a only

This CR is currently configured for tenant-a only:
- Pods run in ztunnel-a namespace
- Pods schedule on mesh=tenant-a nodes only
- Pods connect to istiod-tenant-a.istio-system-a.svc:15012

When tenant-b is added, this CR will need to be updated.
See tenant-b/control-plane/README.md for the strategy.

---

## Lessons learned

### Lesson 1 — name must be "default"

Only one ZTunnel CR per cluster. Name is fixed as "default".
Any other name is rejected by the Sail Operator validation webhook.

### Lesson 2 — values go under values.ztunnel not values

The ZTunnel CR only accepts two top-level keys under values:
global and ztunnel. Fields placed directly under values are
silently stripped by CRD schema pruning — stored as values: {}.

```yaml
# WRONG — silently stripped
values:
  nodeSelector:
    mesh: tenant-a

# CORRECT
values:
  ztunnel:
    nodeSelector:
      mesh: tenant-a
```

Always verify values were accepted:
```bash
oc get ztunnel default -o jsonpath='{.spec.values}'
# Must NOT return {}
```

### Lesson 3 — spec.version required for values to persist

Without spec.version set explicitly, values are silently dropped.

```yaml
spec:
  version: v1.27.5    # required
  values:
    ztunnel: ...
```

### Lesson 4 — istiod Service name includes revision suffix

Sail Operator names the istiod Service after the Istio CR name:
```
Istio CR name: tenant-a  →  Service: istiod-tenant-a
```

xdsAddress must use the full correct service name:
```
WRONG:   istiod.istio-system-a.svc:15012
CORRECT: istiod-tenant-a.istio-system-a.svc:15012
```

Verify after deploying istiod:
```bash
oc get svc -n istio-system-a
```

### Lesson 5 — xdsAddress is more reliable than istioNamespace

values.ztunnel.istioNamespace: istio-system-a did not work.
ztunnel continued connecting to istiod.istio-system.svc.
values.ztunnel.xdsAddress with the full qualified address is
the correct way to point ztunnel at a non-default istiod.

---

## Apply order

```bash
# 1. Namespace first
oc apply -f ztunnel-namespace.yaml

# Confirm label
oc get namespace ztunnel-a --show-labels

# 2. ZTunnel CR
oc apply -f ztunnel.yaml

# Watch until Healthy
oc get ztunnel default -w
# Expected: STATUS=Healthy  VERSION=v1.27.5

# Confirm pods on tenant-a nodes only
oc get pods -n ztunnel-a -o wide
# Expect: 2 pods — ip-10-0-0-5 and ip-10-0-19-190 only
```

---

## Verified output

```
NAME      NAMESPACE   READY   STATUS    VERSION   AGE
default   ztunnel-a   True    Healthy   v1.27.5   11m
```

Pods on tenant-a nodes only:
```
NAME            READY   NODE
ztunnel-88w52   1/1     ip-10-0-19-190.ec2.internal
ztunnel-kd4g7   1/1     ip-10-0-0-5.ec2.internal
```

ztunnel logs confirm connection to correct istiod:
```
received response from istiod-tenant-a.istio-system-a.svc:15012
```

---

## What to do next

```
tenant-a/control-plane/   istio.yaml is already deployed and Healthy
tenant-a/namespaces/      Create bookinfo-a and bookinfo-ingress-a
```
