# tenant-a/policy/

## What this block does

Enforces mTLS and L7 access control for tenant-a workloads.
After this block, only explicitly allowed traffic reaches productpage,
and all connections within the mesh are mutually authenticated.

---

## Files in this directory

| File | Kind | Namespace | Scope |
|---|---|---|---|
| peerauth-meshwide-a.yaml | PeerAuthentication | istio-system-a | Mesh-wide STRICT mTLS for tenant-a |
| peerauth-bookinfo-a.yaml | PeerAuthentication | bookinfo-a | Namespace STRICT mTLS (defence-in-depth) |
| authpolicy-ingress-a.yaml | AuthorizationPolicy | bookinfo-ingress-a | GET only at ingress gateway |
| authpolicy-productpage-a.yaml | AuthorizationPolicy | bookinfo-a | productpage: allow ingress-a + bookinfo-a only |

---

## What changed from SNO

| Field | SNO | tenant-a |
|---|---|---|
| PeerAuth mesh-wide namespace | istio-system | istio-system-a |
| PeerAuth bookinfo namespace | bookinfo | bookinfo-a |
| AuthPolicy ingress namespace | bookinfo-ingress | bookinfo-ingress-a |
| AuthPolicy ingress targetRef | bookinfo-gateway | bookinfo-gateway-a |
| AuthPolicy productpage namespace | bookinfo | bookinfo-a |
| AuthPolicy productpage principal | bookinfo-ingress/sa/bookinfo-gateway-istio | bookinfo-ingress-a/sa/bookinfo-gateway-a-istio |
| AuthPolicy productpage principal | bookinfo/sa/* | bookinfo-a/sa/* |

---

## Mesh-wide PeerAuthentication namespace

The Istio convention is: PeerAuthentication named "default" in the
rootNamespace = mesh-wide policy.

In istio.yaml: rootNamespace = istio-system-a (set by Sail Operator).
Therefore the mesh-wide policy for tenant-a must be in istio-system-a.

```yaml
# WRONG — applies to default mesh only
metadata:
  name: default
  namespace: istio-system

# CORRECT — applies to tenant-a mesh
metadata:
  name: default
  namespace: istio-system-a
```

---

## ServiceAccount naming — Sail Operator appends "-istio"

The Sail Operator appends "-istio" to the Gateway CR name when creating
the ServiceAccount. Always verify before writing principals:

```bash
oc get serviceaccount -n bookinfo-ingress-a
# NAME                       SECRETS   AGE
# bookinfo-gateway-a-istio   1         ...
```

SPIFFE principal format:
```
cluster.local/ns/bookinfo-ingress-a/sa/bookinfo-gateway-a-istio
```

---

## Apply order

```bash
# 1. PeerAuthentication
oc apply -f peerauth-meshwide-a.yaml
oc apply -f peerauth-bookinfo-a.yaml

# 2. AuthorizationPolicy
oc apply -f authpolicy-ingress-a.yaml
oc apply -f authpolicy-productpage-a.yaml

# 3. Verify SA name before testing
oc get serviceaccount -n bookinfo-ingress-a

# 4. Test — GET should succeed
NLB=$(oc get svc -n bookinfo-ingress-a \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w "%{http_code}" http://$NLB/productpage
# Expect: 200

# 5. Test — POST should be denied
curl -s -X POST -o /dev/null -w "%{http_code}" http://$NLB/productpage
# Expect: 403
```

---

## What to do next

```
tenant-a/   Complete ✅
tenant-b/   Mirror all tenant-a files with -b suffix
```

---

## Verified output

```bash
oc get serviceaccount -n bookinfo-ingress-a
# NAME                       SECRETS   AGE
# bookinfo-gateway-a-istio   1         51m  ✅ SA name confirmed

curl -s -o /dev/null -w "%{http_code}" http://$NLB/productpage
# 200  ✅ GET allowed

curl -s -X POST -o /dev/null -w "%{http_code}" http://$NLB/productpage
# 403  ✅ POST denied by AuthorizationPolicy
```
