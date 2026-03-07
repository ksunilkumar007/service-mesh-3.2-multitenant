# operator/

## What this block does

Installs the 5 OLM operators required by the OSSM 3.2 multitenancy stack.
These are identical to the operators used in service-mesh-3.2/ (SNO lab).
They are cluster-scoped and shared — installing once covers all tenants.

---

## Status on spoke1

All operators were already installed and Succeeded when spoke1 was provisioned.
This block does not need to be applied.

```
NAME                                    VERSION     PHASE
cluster-observability-operator.v1.3.1   1.3.1       Succeeded
kiali-operator.v2.17.4                  2.17.4      Succeeded
opentelemetry-operator.v0.144.0-1       0.144.0-1   Succeeded
servicemeshoperator3.v3.2.2             3.2.2       Succeeded
tempo-operator.v0.20.0-1                0.20.0-1    Succeeded
```

Verified with:
```bash
oc get csv -n openshift-operators
```

---

## Files in this directory

Kept here as reference — apply only on a fresh cluster where operators
are not yet installed.

| File | Operator | Channel |
|---|---|---|
| sail-operator.yaml | servicemeshoperator3 | stable-3.2 |
| kiali-operator.yaml | kiali-operator | stable |
| otel-operator.yaml | opentelemetry-operator | stable |
| tempo-operator.yaml | tempo-operator | stable |
| cluster-observability-operator.yaml | cluster-observability-operator | development |

---

## Source

Identical to service-mesh-3.2/operator/*.yaml — no changes needed.
Refer to service-mesh-3.2/mesh/ambient/README.md Lessons 1-3 for
RHACM-specific gotchas around Subscription CRD shadowing.

---

## What to do next

```
shared/cni/   Deploy shared IstioCNI DaemonSet   ← if not already done
```
