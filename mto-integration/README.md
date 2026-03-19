# MTO Integration — Multi-Tenant Operator

Stakater Multi-Tenant Operator (MTO) v1.6.1 integration for the
service mesh ambient mode multi-tenant project.

MTO is the **platform layer** — it owns namespace lifecycle, RBAC,
and resource governance. It does not install or configure Istio.
It creates the namespaces that Istio ambient mode and CUDN then enrol.

---

## Directory layout

```
mto-integration/
├── config/
│   └── mto-integration-config.yaml   IntegrationConfig — APPLY FIRST
├── rbac/
│   └── cluster-roles.yaml            Shared ClusterRoles (all tenants)
├── templates/
│   └── cluster-templates.yaml        Template + TemplateGroupInstance CRs
├── tenant-a/
│   ├── tenant-a.yaml                 Tenant CR + Quota CR
│   └── rbac-a.yaml                   RoleBindings for bookinfo-a/ingress-a
└── tenant-b/
    ├── tenant-b.yaml                 Tenant CR + Quota CR
    └── rbac-b.yaml                   RoleBindings for bookinfo-b/ingress-b
```

---

## API versions — confirmed from oc api-resources on OCP 4.20 / MTO v1.6.1

| Kind                  | apiVersion                           | Namespaced | Notes                         |
|-----------------------|--------------------------------------|------------|-------------------------------|
| IntegrationConfig     | tenantoperator.stakater.com/v1beta1  | true       | One per cluster               |
| Tenant                | tenantoperator.stakater.com/v1beta3  | false      | One per tenant                |
| Quota                 | tenantoperator.stakater.com/v1beta1  | false      | One per tenant                |
| Template              | tenantoperator.stakater.com/v1alpha1 | false      | One per resource type         |
| TemplateGroupInstance | tenantoperator.stakater.com/v1alpha1 | false      | Pushes Template to namespaces |

Always verify with `oc api-resources | grep tenantoperator` before
writing manifests — MTO API versions change between minor releases.

---

## What MTO manages

| Concern                   | How                                                              |
|---------------------------|------------------------------------------------------------------|
| Namespace creation        | `spec.namespaces.withoutTenantPrefix` in `Tenant` CR            |
| Labels on all namespaces  | `spec.namespaces.metadata.common.labels` — self-healing         |
| Labels on specific ns     | `spec.namespaces.metadata.specific[].labels` — per-namespace    |
| RBAC                      | `spec.accessControl.owners/viewers` + explicit RoleBindings     |
| ResourceQuota             | `Quota.spec.resourcequota.hard` referenced in `Tenant.spec.quota`|
| LimitRange                | `Quota.spec.limitrange` — in same Quota CR                      |
| NetworkPolicy baseline    | `Template: tenant-network-policy` via `TemplateGroupInstance`   |

## What MTO does NOT manage

- Istio control plane (istiod, ztunnel, CNI) — owned by Sail operator
- Waypoint proxies — per-tenant, in `tenant-a/gateways/`
- Gateway API objects (Gateway, HTTPRoute) — per-tenant
- AuthorizationPolicy / PeerAuthentication — per-tenant
- CUDN / UDN — owned by OVN-Kubernetes

---

## Apply order

MTO's admission webhook (`vnamespace.kb.io`) goes live the moment
the MTO CSV reaches `Succeeded`. **IntegrationConfig must be applied
before any other namespace creation** — otherwise the webhook blocks
everything including `istio-cni`, `istio-system`, and `ztunnel`.

```bash
# 1. Unblock MTO webhook — ALWAYS FIRST
oc apply -f mto-integration/config/mto-integration-config.yaml

# 2. Shared ClusterRoles — must exist before any RoleBinding references them
oc apply -f mto-integration/rbac/cluster-roles.yaml

# 3. Templates + TemplateGroupInstances
oc apply -f mto-integration/templates/cluster-templates.yaml

# 4. Shared Istio control plane (webhook now allows these namespaces)
oc apply -f shared/cni/
oc apply -f shared/control-plane/
oc apply -f shared/ztunnel/

# 5. Tenant CRs — MTO creates namespaces and stamps all labels
oc apply -f mto-integration/tenant-a/tenant-a.yaml
oc apply -f mto-integration/tenant-b/tenant-b.yaml

# GATE — confirm all labels present on all 4 namespaces
oc get ns bookinfo-a bookinfo-ingress-a bookinfo-b bookinfo-ingress-b \
  --show-labels

# 6. Tenant RoleBindings — namespaces must exist first
oc apply -f mto-integration/tenant-a/rbac-a.yaml
oc apply -f mto-integration/tenant-b/rbac-b.yaml

# 7. CUDN — mesh labels now present, OVN-K can inject NADs
oc apply -f cudn/cudn-tenant-a.yaml
oc apply -f cudn/cudn-tenant-b.yaml

# Verify NAD injected into all 4 namespaces
oc describe clusteruserdefinednetwork cudn-tenant-a | grep "Message:"
oc describe clusteruserdefinednetwork cudn-tenant-b | grep "Message:"
```

---

## IntegrationConfig — privileged namespaces

The `IntegrationConfig` exempts platform and infra namespaces from
MTO's tenant ownership requirement.

```
istio-system, istio-cni, ztunnel     Istio ambient control plane
opentelemetry-operator-system        OTel operator
tracing, monitoring                  Observability stack
multi-tenant-operator                MTO itself
openshift-.*                         All OpenShift platform namespaces
kube-.*                              Kubernetes system namespaces
```

### Lesson learned — IntegrationConfig field names

Old fields that do NOT exist in v1beta1 (produce silent failures):

```yaml
spec:
  tenantOperator:        # WRONG
    privilegedNamespaces:
  openShift:             # WRONG
    project:
```

Correct v1beta1 fields:

```yaml
spec:
  accessControl:
    privileged:
      namespaces:
        - ^istio-system$
        - ^openshift-.*
      serviceAccounts:
        - ^system:serviceaccount:istio-system:.*
```

Using wrong fields produces `unknown field` warnings and exemptions
are silently ignored — the webhook still blocks everything.
Always delete and recreate (not patch) when fixing field names.

---

## Tenant CR — namespace label structure

MTO v1beta3 provides two ways to set namespace labels:

```yaml
spec:
  namespaces:
    metadata:
      common:                          # applied to ALL tenant namespaces
        labels:
          mesh: tenant-a
          istio-discovery: enabled
          istio.io/dataplane-mode: ambient

      specific:                        # applied to NAMED namespaces only
        - namespaces: [bookinfo-a]
          labels:
            istio.io/use-waypoint: waypoint
            stakater.com/mesh-waypoint: "true"

        - namespaces: [bookinfo-ingress-a]
          labels:
            stakater.com/tenant-ingress: tenant-a
```

**Why `istio.io/use-waypoint` is NOT on the ingress namespace:**
The gateway pod in `bookinfo-ingress-a` is the traffic entry point.
Setting `use-waypoint` on the ingress namespace would redirect
gateway traffic back through the waypoint incorrectly. L7 enforcement
via `AuthorizationPolicy` happens in `bookinfo-a` where the waypoint
lives — not in the ingress namespace.

### Lessons learned — Tenant CR

**`TenantNamespace` CRD does not exist in MTO v1.6.**
Namespaces are defined inline in `Tenant.spec.namespaces.withoutTenantPrefix`.

**`spec.owners` / `spec.viewers` do not exist in v1beta3.**
Correct field is `spec.accessControl.owners` / `spec.accessControl.viewers`.

**`spec.namespaces.metadata.labels` does not exist.**
Labels go under `spec.namespaces.metadata.common.labels` or
`spec.namespaces.metadata.specific[].labels`.

**`spec.templateInstances` does not exist in v1beta3.**
Use standalone `TemplateGroupInstance` CRs that select namespaces
by label — they work independently of the Tenant CR.

---

## Quota CR — correct field structure

```yaml
# WRONG — spec.hard does not exist at top level
spec:
  hard:
    requests.cpu: "8"

# CORRECT
spec:
  resourcequota:
    hard:
      requests.cpu: "8"
      requests.memory: 16Gi
      limits.cpu: "16"
      limits.memory: 32Gi
      pods: "100"
  limitrange:
    limits:
      - type: Container
        default:
          cpu: 500m
          memory: 512Mi
        defaultRequest:
          cpu: 100m
          memory: 128Mi
```

---

## Templates vs ClusterTemplates

MTO v1.6 does not have a `ClusterTemplate` kind.
The correct pattern is `Template` + `TemplateGroupInstance`:

```
Template                   defines the Kubernetes resource to create
TemplateGroupInstance      selects namespaces via spec.selector.matchLabels
                           and pushes the Template into each matching namespace
```

The three TemplateGroupInstances in `templates/cluster-templates.yaml`
select on `stakater.com/mesh-profile: ambient` — stamped on every
tenant namespace via the `Tenant` CR `common` labels block.

---

## Namespace labels stamped by MTO

| Label                          | bookinfo-a  | bookinfo-ingress-a | Purpose                                    |
|--------------------------------|-------------|--------------------|--------------------------------------------|
| `mesh`                         | `tenant-a`  | `tenant-a`         | istiod discoverySelector + CUDN selector   |
| `istio-discovery`              | `enabled`   | `enabled`          | Required for OTel tracing via Telemetry CR |
| `istio-injection`              | `disabled`  | `disabled`         | Prevents accidental sidecar injection      |
| `istio.io/dataplane-mode`      | `ambient`   | `ambient`          | Enrols pods via ztunnel                    |
| `istio.io/use-waypoint`        | `waypoint`  | —                  | L7 enforcement (workload ns only)          |
| `openshift.io/user-monitoring` | `true`      | `true`             | OCP user workload monitoring               |
| `stakater.com/mesh-profile`    | `ambient`   | `ambient`          | TemplateGroupInstance selector             |
| `stakater.com/mesh-waypoint`   | `true`      | —                  | Workload ns marker                         |
| `stakater.com/tenant-ingress`  | —           | `tenant-a`         | NetworkPolicy cross-ns traffic selector    |
| `topology.kubernetes.io/tenant`| `tenant-a`  | `tenant-a`         | Node affinity to tainted node pool         |

---

## RBAC structure

```
rbac/cluster-roles.yaml      ClusterRole: tenant-mesh-admin   (cluster-scoped, defined ONCE)
                             ClusterRole: tenant-mesh-viewer   (shared by all tenants)

tenant-a/rbac-a.yaml        RoleBinding: admin  → bookinfo-a
                             RoleBinding: admin  → bookinfo-ingress-a
                             RoleBinding: viewer → bookinfo-a
                             RoleBinding: viewer → bookinfo-ingress-a

tenant-b/rbac-b.yaml        RoleBinding: admin  → bookinfo-b
                             RoleBinding: admin  → bookinfo-ingress-b
                             RoleBinding: viewer → bookinfo-b
                             RoleBinding: viewer → bookinfo-ingress-b
```

`rbac-a.yaml` and `rbac-b.yaml` contain RoleBindings only.
`cluster-roles.yaml` must be applied before either file.
RoleBindings must be applied after the Tenant CR creates the namespaces.

---

## Shared namespace label requirement

All shared control plane namespaces must carry `istio-discovery: enabled`
so istiod discovers them and injects the `istio-ca-root-cert` ConfigMap.
Without this label ztunnel pods fail on startup:

```
MountVolume.SetUp failed for volume "istiod-ca-cert":
configmap "istio-ca-root-cert" not found
```

Verify all three shared namespace files carry the correct label:

```bash
grep -H "istio-discovery" \
  shared/cni/istio-cni-namespace.yaml \
  shared/control-plane/istio-namespace.yaml \
  shared/ztunnel/ztunnel-namespace.yaml
# must show: istio-discovery: enabled
# NOT:       istio-discovery-a: enabled  (old per-tenant istiod design)
```

---

## Adding a new tenant (Day 2)

```bash
# 1. Copy tenant-a as a template
cp -r mto-integration/tenant-a mto-integration/tenant-c
sed -i '' 's/tenant-a/tenant-c/g; s/bookinfo-a/bookinfo-c/g' \
  mto-integration/tenant-c/tenant-a.yaml
mv mto-integration/tenant-c/tenant-a.yaml mto-integration/tenant-c/tenant-c.yaml
mv mto-integration/tenant-c/rbac-a.yaml   mto-integration/tenant-c/rbac-c.yaml

# 2. Add CUDN (next available subnet slot is 10.200.3.0/24)
# Copy cudn/cudn-tenant-b.yaml and substitute tenant-b with tenant-c

# 3. Apply
oc apply -f mto-integration/tenant-c/tenant-c.yaml
oc apply -f mto-integration/tenant-c/rbac-c.yaml
oc apply -f cudn/cudn-tenant-c.yaml
```

MTO creates namespaces, stamps all labels, applies NetworkPolicy
via TemplateGroupInstance automatically. CUDN selects the new
namespaces via `mesh: tenant-c`. No shell scripts required.

---

## Relationship to other project directories

```
operator/           OLM Subscriptions for all operators including MTO
mto-integration/    MTO config and tenant definitions (this directory)
cudn/               CUDN Layer2 secondary network — deployed AFTER MTO
shared/             Istio ambient control plane (CNI, istiod, ztunnel)
tenant-a/           Per-tenant mesh config (gateways, policy) — unchanged
tenant-b/           Per-tenant mesh config (gateways, policy) — unchanged
nodepools/          Node labelling + taint scripts — run once per cluster
```
