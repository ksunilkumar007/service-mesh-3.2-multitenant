#!/usr/bin/env bash
# =============================================================================
# setup-lab.sh — service-mesh-3.2-multitenant full lab setup
#
# Deploys the complete stack in correct order with health gates:
#   Phase 0 — Pre-flight checks
#   Phase 1 — Node pools (label + taint)
#   Phase 2 — MTO IntegrationConfig (unblock webhook)
#   Phase 3 — MTO RBAC + Templates
#   Phase 4 — Istio shared control plane (CNI, istiod, ztunnel)
#   Phase 5 — MTO Tenant CRs (creates namespaces with labels)
#   Phase 6 — CUDN (L2 secondary network)
#   Phase 7 — Tenant mesh config (gateways, policy)
#   Phase 8 — MetalLB (LoadBalancer IPs)
#   Phase 9 — Bookinfo app deployment
#   Phase 10 — Observability (OTel, Tempo, Kiali, Prometheus)
#   Phase 11 — OpenShift Routes (external access)
#   Phase 12 — Validation
#
# Usage:
#   ./setup-lab.sh                    # full deployment
#   ./setup-lab.sh --from-phase 6     # resume from phase 6
#   ./setup-lab.sh --dry-run          # show commands without running
#
# Requirements: oc (logged in as cluster-admin), jq
# Compatibility: bash 3.2+ (macOS zsh compatible)
# =============================================================================

set -uo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}✔${RESET}  $*"; }
fail()  { echo -e "  ${RED}✗${RESET}  $*"; exit 1; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
info()  { echo -e "  ${CYAN}→${RESET}  $*"; }
title() { echo -e "\n${BOLD}═══ $* ═══${RESET}\n"; }
run()   {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "  ${CYAN}[dry-run]${RESET} $*"
  else
    info "Running: $*"
    eval "$*"
  fi
}

# ── defaults ─────────────────────────────────────────────────────────────────
FROM_PHASE=0
DRY_RUN=false
BOOKINFO_VERSION="release-1.27"

while [[ $# -gt 0 ]]; do
  case $1 in
    --from-phase) FROM_PHASE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

should_run() { [[ "$1" -ge "$FROM_PHASE" ]]; }

# ── wait helper ───────────────────────────────────────────────────────────────
wait_for_pods() {
  local ns=$1 label=$2 expected=$3 timeout=${4:-120}
  info "Waiting for $expected pods with $label in $ns (timeout ${timeout}s)..."
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local running
    running=$(oc get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | \
      grep Running | wc -l | tr -d ' ')
    if [[ "$running" -ge "$expected" ]]; then
      pass "$ns — $running/$expected pods Running"
      return 0
    fi
    sleep 5; elapsed=$((elapsed+5))
    echo -n "."
  done
  echo ""
  fail "$ns — only $running/$expected pods Running after ${timeout}s"
}

wait_for_csv() {
  local ns=$1 name=$2 timeout=${3:-180}
  info "Waiting for CSV $name in $ns..."
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local phase
    phase=$(oc get csv -n "$ns" --no-headers 2>/dev/null | \
      grep "$name" | awk '{print $NF}')
    if [[ "$phase" == "Succeeded" ]]; then
      pass "CSV $name — Succeeded"
      return 0
    fi
    sleep 5; elapsed=$((elapsed+5))
    echo -n "."
  done
  echo ""
  fail "CSV $name did not reach Succeeded after ${timeout}s"
}

wait_for_ns() {
  local ns=$1 timeout=${2:-60}
  info "Waiting for namespace $ns..."
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if oc get ns "$ns" &>/dev/null; then
      pass "Namespace $ns exists"
      return 0
    fi
    sleep 3; elapsed=$((elapsed+3))
    echo -n "."
  done
  echo ""
  fail "Namespace $ns did not appear after ${timeout}s"
}

# =============================================================================
echo ""
echo -e "${BOLD}service-mesh-3.2-multitenant — lab setup${RESET}"
echo -e "Starting from phase: ${FROM_PHASE}"
echo -e "Dry run: ${DRY_RUN}"
echo ""

# =============================================================================
# Phase 0 — Pre-flight
# =============================================================================
should_run 0 && {
title "Phase 0 — Pre-flight checks"

# oc logged in
oc whoami &>/dev/null || fail "Not logged in — run: oc login"
pass "oc logged in as $(oc whoami)"

# cluster-admin
oc auth can-i '*' '*' --all-namespaces &>/dev/null || \
  fail "Not cluster-admin — need elevated privileges"
pass "cluster-admin confirmed"

# jq available
which jq &>/dev/null || fail "jq not found — brew install jq"
pass "jq available"

# correct directory
[[ -f "validate.sh" ]] || fail "Run from project root (service-mesh-3.2-multitenant/)"
pass "Running from project root"

# network config verify
info "Running network-config-verify.sh..."
bash cudn/network-config-verify.sh || fail "Network config check failed"
}

# =============================================================================
# Phase 1 — Node pools
# =============================================================================
should_run 1 && {
title "Phase 1 — Node pools (label + taint)"

run "bash nodepools/label-infra.sh"
run "bash nodepools/label-taint-tenant-a.sh"
run "bash nodepools/label-taint-tenant-b.sh"

# verify
pass "Node pool labels and taints applied"
oc get nodes -o custom-columns=\
NAME:.metadata.name,\
MESH:.metadata.labels.mesh,\
TAINTS:.spec.taints \
  --no-headers 2>/dev/null | grep -v "<none>" || true
}

# =============================================================================
# Phase 2 — MTO IntegrationConfig (MUST be first — unblocks webhook)
# =============================================================================
should_run 2 && {
title "Phase 2 — MTO IntegrationConfig (unblock webhook)"

run "oc apply -f mto-integration/config/mto-integration-config.yaml"

# wait for it to be accepted
sleep 3
oc get integrationconfig tenant-operator-config \
  -n multi-tenant-operator &>/dev/null && \
  pass "IntegrationConfig applied" || \
  warn "IntegrationConfig may not be ready yet"
}

# =============================================================================
# Phase 3 — MTO RBAC + Templates
# =============================================================================
should_run 3 && {
title "Phase 3 — MTO shared RBAC + ClusterTemplates"

run "oc apply -f mto-integration/rbac/cluster-roles.yaml"
run "oc apply -f mto-integration/templates/cluster-templates.yaml"

pass "ClusterRoles and TemplateGroupInstances applied"
}

# =============================================================================
# Phase 4 — Istio shared control plane
# =============================================================================
should_run 4 && {
title "Phase 4 — Istio shared control plane (CNI + istiod + ztunnel)"

run "oc apply -f shared/cni/"
run "oc apply -f shared/control-plane/"
run "oc apply -f shared/ztunnel/"

wait_for_ns "istio-system" 60
wait_for_ns "ztunnel" 60
wait_for_pods "istio-system" "app=istiod" 1 180
wait_for_pods "istio-cni" "app=istio-cni-node" 1 180
wait_for_pods "ztunnel" "app=ztunnel" 1 180
}

# =============================================================================
# Phase 5 — MTO Tenant CRs (creates namespaces + labels)
# =============================================================================
should_run 5 && {
title "Phase 5 — MTO Tenant CRs (namespace creation)"

run "oc apply -f mto-integration/tenant-a/tenant-a.yaml"
run "oc apply -f mto-integration/tenant-b/tenant-b.yaml"

# wait for namespaces to appear with correct labels
info "Waiting for tenant namespaces..."
local elapsed=0
while [[ $elapsed -lt 120 ]]; do
  if oc get ns bookinfo-a bookinfo-b bookinfo-ingress-a bookinfo-ingress-b \
    &>/dev/null 2>&1; then
    pass "All 4 tenant namespaces created"
    break
  fi
  sleep 5; elapsed=$((elapsed+5)); echo -n "."
done
echo ""

# apply RoleBindings after namespaces exist
run "oc apply -f mto-integration/tenant-a/rbac-a.yaml"
run "oc apply -f mto-integration/tenant-b/rbac-b.yaml"

# verify labels
info "Verifying namespace labels..."
for ns in bookinfo-a bookinfo-ingress-a bookinfo-b bookinfo-ingress-b; do
  label=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null)
  if [[ "$label" == "ambient" ]]; then
    pass "$ns — istio.io/dataplane-mode=ambient"
  else
    warn "$ns — ambient label missing (MTO may still be reconciling)"
  fi
done
}

# =============================================================================
# Phase 6 — CUDN (L2 secondary network)
# =============================================================================
should_run 6 && {
title "Phase 6 — CUDN (L2 secondary network)"

run "oc apply -f cudn/cudn-tenant-a.yaml"
run "oc apply -f cudn/cudn-tenant-b.yaml"

# wait for NAD injection
info "Waiting for CUDN NAD injection..."
local elapsed=0
while [[ $elapsed -lt 60 ]]; do
  msg_a=$(oc describe clusteruserdefinednetwork cudn-tenant-a 2>/dev/null | \
    grep "Message:" | grep "bookinfo" || true)
  if [[ -n "$msg_a" ]]; then
    pass "cudn-tenant-a NAD injected into bookinfo-a namespaces"
    break
  fi
  sleep 5; elapsed=$((elapsed+5)); echo -n "."
done
echo ""
}

# =============================================================================
# Phase 7 — Tenant mesh config
# =============================================================================
should_run 7 && {
title "Phase 7 — Tenant mesh config (gateways + policy)"

run "oc apply -f tenant-a/gateways/"
run "oc apply -f tenant-a/policy/"
run "oc apply -f tenant-b/gateways/"
run "oc apply -f tenant-b/policy/"
run "oc apply -f shared/policy/"

# wait for waypoints
wait_for_pods "bookinfo-a" "gateway.networking.k8s.io/gateway-name=waypoint" 1 120
wait_for_pods "bookinfo-b" "gateway.networking.k8s.io/gateway-name=waypoint" 1 120
}

# =============================================================================
# Phase 8 — MetalLB
# =============================================================================
should_run 8 && {
title "Phase 8 — MetalLB (LoadBalancer IPs)"

# check if already installed
if oc get csv -n metallb-system 2>/dev/null | grep -q "metallb.*Succeeded"; then
  pass "MetalLB operator already installed"
else
  run "oc apply -f operator/metallb-operator.yaml"
  wait_for_csv "metallb-system" "metallb" 180
fi

# MetalLB instance
run "oc apply -f metallb/metallb-namespace.yaml"
wait_for_pods "metallb-system" "component=controller" 1 120
wait_for_pods "metallb-system" "component=speaker" 5 120

# IP pool
run "oc apply -f metallb/metallb-pool.yaml"

pass "MetalLB deployed"
}

# =============================================================================
# Phase 9 — Bookinfo app + OpenShift Routes
# =============================================================================
should_run 9 && {
title "Phase 9 — Bookinfo app deployment"

BOOKINFO_URL="https://raw.githubusercontent.com/istio/istio/${BOOKINFO_VERSION}/samples/bookinfo/platform/kube/bookinfo.yaml"

run "oc apply -n bookinfo-a -f ${BOOKINFO_URL}"
run "oc apply -n bookinfo-b -f ${BOOKINFO_URL}"

wait_for_pods "bookinfo-a" "app=productpage" 1 180
wait_for_pods "bookinfo-b" "app=productpage" 1 180

# patch deployments with nodeSelector + toleration + CUDN annotation
info "Patching bookinfo-a deployments (nodeSelector + CUDN)..."
for deploy in details-v1 productpage-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
  run "oc patch deployment $deploy -n bookinfo-a --type=merge -p '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"k8s.v1.cni.cncf.io/networks\":\"cudn-tenant-a\"}},\"spec\":{\"nodeSelector\":{\"mesh\":\"tenant-a\"},\"tolerations\":[{\"key\":\"mesh\",\"operator\":\"Equal\",\"value\":\"tenant-a\",\"effect\":\"NoSchedule\"}]}}}}'"
done

info "Patching bookinfo-b deployments (nodeSelector + CUDN)..."
for deploy in details-v1 productpage-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
  run "oc patch deployment $deploy -n bookinfo-b --type=merge -p '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"k8s.v1.cni.cncf.io/networks\":\"cudn-tenant-b\"}},\"spec\":{\"nodeSelector\":{\"mesh\":\"tenant-b\"},\"tolerations\":[{\"key\":\"mesh\",\"operator\":\"Equal\",\"value\":\"tenant-b\",\"effect\":\"NoSchedule\"}]}}}}'"
done

wait_for_pods "bookinfo-a" "app=productpage" 1 180
wait_for_pods "bookinfo-b" "app=productpage" 1 180

# OpenShift Routes for external access
info "Creating OpenShift Routes..."
run "oc expose svc bookinfo-gateway-a-istio -n bookinfo-ingress-a --name=bookinfo-a --port=80 2>/dev/null || true"
run "oc expose svc bookinfo-gateway-b-istio -n bookinfo-ingress-b --name=bookinfo-b --port=80 2>/dev/null || true"

ROUTE_A=$(oc get route bookinfo-a -n bookinfo-ingress-a \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
ROUTE_B=$(oc get route bookinfo-b -n bookinfo-ingress-b \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

pass "tenant-a: http://${ROUTE_A}/productpage"
pass "tenant-b: http://${ROUTE_B}/productpage"
}

# =============================================================================
# Phase 10 — Observability
# =============================================================================
should_run 10 && {
title "Phase 10 — Observability (OTel + Tempo + Kiali + Prometheus)"

run "oc apply -f shared/observability/"
wait_for_ns "tracing" 60
run "oc apply -f shared/observability/"   # second apply — namespace now exists

# create tempo S3 secret from NooBaa OBC
info "Waiting for NooBaa OBC to be Bound..."
local elapsed=0
while [[ $elapsed -lt 120 ]]; do
  phase=$(oc get objectbucketclaim tempo-bucket -n tracing \
    -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$phase" == "Bound" ]]; then
    pass "OBC tempo-bucket Bound"
    break
  fi
  sleep 5; elapsed=$((elapsed+5)); echo -n "."
done
echo ""

# create tempo-s3-secret from OBC credentials
if ! oc get secret tempo-s3-secret -n tracing &>/dev/null; then
  BUCKET_NAME=$(oc get cm tempo-bucket -n tracing \
    -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null)
  BUCKET_HOST=$(oc get cm tempo-bucket -n tracing \
    -o jsonpath='{.data.BUCKET_HOST}' 2>/dev/null)
  BUCKET_PORT=$(oc get cm tempo-bucket -n tracing \
    -o jsonpath='{.data.BUCKET_PORT}' 2>/dev/null)
  ACCESS_KEY=$(oc get secret tempo-bucket -n tracing \
    -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d)
  SECRET_KEY=$(oc get secret tempo-bucket -n tracing \
    -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d)

  run "oc create secret generic tempo-s3-secret -n tracing \
    --from-literal=bucket=${BUCKET_NAME} \
    --from-literal=endpoint=https://${BUCKET_HOST}:${BUCKET_PORT} \
    --from-literal=access_key_id=${ACCESS_KEY} \
    --from-literal=access_key_secret=${SECRET_KEY}"
  pass "tempo-s3-secret created"
else
  pass "tempo-s3-secret already exists"
fi

run "oc apply -f shared/observability/tempostack-odf.yaml"
run "oc apply -f shared/kiali/"
run "oc apply -f shared/monitoring/"
run "oc apply -f shared/observability/monitors/"

wait_for_pods "istio-system" "app=kiali" 1 180
pass "Observability stack deployed"

KIALI_URL=$(oc get route kiali -n istio-system \
  -o jsonpath='{.spec.host}' 2>/dev/null)
pass "Kiali: https://${KIALI_URL}"
}

# =============================================================================
# Phase 11 — Validation
# =============================================================================
should_run 11 && {
title "Phase 11 — Full validation"

run "bash validate.sh"
}

# =============================================================================
# Summary
# =============================================================================
title "Setup Complete"

echo ""
echo -e "${BOLD}Access URLs:${RESET}"
ROUTE_A=$(oc get route bookinfo-a -n bookinfo-ingress-a \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "not-created")
ROUTE_B=$(oc get route bookinfo-b -n bookinfo-ingress-b \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "not-created")
KIALI=$(oc get route kiali -n istio-system \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "not-created")

echo -e "  Bookinfo tenant-a  : http://${ROUTE_A}/productpage"
echo -e "  Bookinfo tenant-b  : http://${ROUTE_B}/productpage"
echo -e "  Kiali              : https://${KIALI}"
echo ""
echo -e "${BOLD}Generate traffic:${RESET}"
echo -e "  bash generate-traffic.sh --duration 300"
echo ""
