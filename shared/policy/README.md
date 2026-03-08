# shared/policy/

## Files

| File | Kind | Namespace | Scope |
|---|---|---|---|
| peerauth-meshwide.yaml | PeerAuthentication | istio-system | Mesh-wide STRICT mTLS for all tenants |

---

## Cross-tenant isolation

Cross-tenant traffic is blocked by the per-tenant ALLOW-only AuthorizationPolicy
on each waypoint. No explicit DENY policy is needed.

### How it works

Each tenant's productpage AuthorizationPolicy only allows:
- Its own ingress gateway SA (`bookinfo-ingress-a/sa/bookinfo-gateway-a-istio`)
- Its own namespace SAs (`bookinfo-a/sa/*`)

Any request from a different tenant namespace does not match either rule
and is implicitly denied by the waypoint at L7.

### Verified

```
bookinfo-a → bookinfo-b/productpage   HTTP 403 ✅
bookinfo-b → bookinfo-a/productpage   HTTP 403 ✅
```

### Why this is sufficient

Istio AuthorizationPolicy default-deny behaviour:
- No policy exists      → ALL traffic allowed
- ANY ALLOW policy exists → ONLY matching traffic passes, everything else DENIED

Since both productpage waypoints have ALLOW policies scoped to their own
tenant, cross-tenant traffic is implicitly denied without any explicit
DENY rule.

---

## Mesh-wide PeerAuthentication

Single policy for all tenants in `istio-system` (the rootNamespace).
Per-tenant namespace policies in `tenant-a/policy/` and `tenant-b/policy/`
provide defence-in-depth on top of this mesh-wide baseline.
