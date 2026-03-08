#!/bin/bash
# =============================================================================
# service-mesh-3.2-multitenant — end to end validation script
# Tests: mesh health, node pool isolation, mTLS, waypoints,
#        ingress (AWS NLB), AuthorizationPolicy, cross-tenant isolation,
#        distributed tracing (Tempo + OTel), observability (Prometheus)
# =============================================================================

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "${GREEN}  PASS${NC}  $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}  FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "${YELLOW}  WARN${NC}  $1"; WARN=$((WARN+1)); }
section() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }
tenant() { echo -e "\n${CYAN}  ── $1 ──${NC}"; }

# =============================================================================
# SECTION 1 — Control plane health
# =============================================================================
section "Control plane"

STATUS=$(oc get istio default -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
[[ "$STATUS" == "Healthy" ]] && pass "Istio CR: Healthy" || fail "Istio CR: $STATUS"

STATUS=$(oc get istiocni default -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
[[ "$STATUS" == "Healthy" ]] && pass "IstioCNI CR: Healthy" || fail "IstioCNI CR: $STATUS"

STATUS=$(oc get ztunnel default -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
[[ "$STATUS" == "Healthy" ]] && pass "ZTunnel CR: Healthy" || fail "ZTunnel CR: $STATUS"

READY=$(oc get pods -n istio-system -l app=istiod \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[[ "$READY" == "True" ]] && pass "istiod pod: Ready" || fail "istiod pod: not Ready"

# Verify profile=ambient (PILOT_ENABLE_AMBIENT)
PROFILE=$(oc get istio default -o jsonpath='{.spec.profile}' 2>/dev/null)
[[ "$PROFILE" == "ambient" ]] && pass "Istio profile: ambient" || fail "Istio profile: '${PROFILE}' (expected ambient — missing profile breaks ztunnel)"

# Verify defaultProviders.tracing set (required for waypoint tracing)
TRACING_PROVIDER=$(oc get istio default \
  -o jsonpath='{.spec.values.meshConfig.defaultProviders.tracing[0]}' 2>/dev/null)
[[ "$TRACING_PROVIDER" == "otel-tracing" ]] \
  && pass "meshConfig.defaultProviders.tracing: otel-tracing" \
  || fail "meshConfig.defaultProviders.tracing: '${TRACING_PROVIDER}' (required for waypoint tracing)"

# ztunnel pods — all nodes
ZTUNNEL_TOTAL=$(oc get pods -n ztunnel --no-headers 2>/dev/null | wc -l)
ZTUNNEL_READY=$(oc get pods -n ztunnel --no-headers 2>/dev/null | grep -c "1/1")
[[ "$ZTUNNEL_READY" == "$ZTUNNEL_TOTAL" ]] \
  && pass "ztunnel pods: ${ZTUNNEL_READY}/${ZTUNNEL_TOTAL} Ready" \
  || fail "ztunnel pods: ${ZTUNNEL_READY}/${ZTUNNEL_TOTAL} Ready"

# CNI pods
CNI_TOTAL=$(oc get pods -n istio-cni --no-headers 2>/dev/null | wc -l)
CNI_READY=$(oc get pods -n istio-cni --no-headers 2>/dev/null | grep -c "1/1")
[[ "$CNI_READY" == "$CNI_TOTAL" ]] \
  && pass "CNI pods: ${CNI_READY}/${CNI_TOTAL} Ready" \
  || fail "CNI pods: ${CNI_READY}/${CNI_TOTAL} Ready"

# =============================================================================
# SECTION 2 — Namespace labels
# =============================================================================
section "Namespace labels"

check_label() {
  local NS=$1 KEY=$2 VAL=$3
  # Use python3 to handle label keys with dots and slashes
  local ACTUAL=$(oc get namespace $NS -o json 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['metadata']['labels'].get('${KEY}',''))" 2>/dev/null)
  [[ "$ACTUAL" == "$VAL" ]] \
    && pass "ns/${NS}: ${KEY}=${VAL}" \
    || fail "ns/${NS}: ${KEY}=${ACTUAL} (expected ${VAL})"
}

for NS in istio-system istio-cni ztunnel tracing; do
  check_label $NS "istio-discovery" "enabled"
done

for NS in bookinfo-a bookinfo-ingress-a bookinfo-b bookinfo-ingress-b; do
  check_label $NS "istio-discovery" "enabled"
  check_label $NS "istio-injection" "disabled"
  check_label $NS "istio.io/dataplane-mode" "ambient"
done

check_label bookinfo-a      "mesh" "tenant-a"
check_label bookinfo-ingress-a "mesh" "tenant-a"
check_label bookinfo-b      "mesh" "tenant-b"
check_label bookinfo-ingress-b "mesh" "tenant-b"

check_label bookinfo-a "istio.io/use-waypoint" "waypoint"
check_label bookinfo-b "istio.io/use-waypoint" "waypoint"

# Verify stale istio.io/rev label is gone
for NS in bookinfo-a bookinfo-ingress-a bookinfo-b bookinfo-ingress-b; do
  REV=$(oc get namespace $NS -o jsonpath='{.metadata.labels.istio\.io/rev}' 2>/dev/null)
  [[ -z "$REV" ]] \
    && pass "ns/${NS}: istio.io/rev removed (no stale per-tenant istiod label)" \
    || warn "ns/${NS}: istio.io/rev=${REV} (stale label from old per-tenant istiod design)"
done

# =============================================================================
# SECTION 3 — Node pool isolation
# =============================================================================
section "Node pool isolation"

ZTUNNEL_POD=$(oc get pods -n ztunnel -l app=ztunnel \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

for TENANT in a b; do
  tenant "Tenant-${TENANT^^} node pool"
  NS="bookinfo-${TENANT}"
  POOL="tenant-${TENANT}"

  # Check all bookinfo pods are on correct node pool
  PODS=$(oc get pods -n $NS --no-headers 2>/dev/null | grep -v "curl-test\|Completed" | awk '{print $1}')
  for POD in $PODS; do
    NODE=$(oc get pod $POD -n $NS -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    NODE_POOL=$(oc get node $NODE -o jsonpath="{.metadata.labels.mesh}" 2>/dev/null)
    [[ "$NODE_POOL" == "$POOL" ]] \
      && pass "${NS}/${POD}: on node pool ${POOL} (${NODE})" \
      || fail "${NS}/${POD}: on node pool '${NODE_POOL}' (expected ${POOL})"
  done

  # Check waypoint is on correct node pool
  WP_POD=$(oc get pods -n bookinfo-ingress-${TENANT} --no-headers 2>/dev/null | grep gateway | awk '{print $1}' | head -1)
  if [[ -n "$WP_POD" ]]; then
    NODE=$(oc get pod $WP_POD -n bookinfo-ingress-${TENANT} -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    NODE_POOL=$(oc get node $NODE -o jsonpath="{.metadata.labels.mesh}" 2>/dev/null)
    [[ "$NODE_POOL" == "$POOL" ]] \
      && pass "bookinfo-ingress-${TENANT} gateway: on node pool ${POOL} (${NODE})" \
      || fail "bookinfo-ingress-${TENANT} gateway: on node pool '${NODE_POOL}' (expected ${POOL})"
  fi
done

# =============================================================================
# SECTION 4 — Bookinfo pods (per tenant)
# =============================================================================
section "Bookinfo pods"

for TENANT in a b; do
  tenant "Tenant-${TENANT^^}"
  NS="bookinfo-${TENANT}"
  for APP in details productpage ratings reviews-v1 reviews-v2 reviews-v3; do
    POD_READY=$(oc get pods -n $NS --no-headers 2>/dev/null | grep "^${APP}" | head -1 | awk '{print $2}')
    [[ "$POD_READY" == "1/1" ]] \
      && pass "${NS}/${APP}: 1/1 Running (ambient)" \
      || fail "${NS}/${APP}: ${POD_READY} (expected 1/1)"
  done
done

# =============================================================================
# SECTION 5 — Ambient enrollment
# =============================================================================
section "Ambient enrollment (HBONE)"

for TENANT in a b; do
  tenant "Tenant-${TENANT^^}"
  NS="bookinfo-${TENANT}"
  for APP in details productpage ratings reviews; do
    PROTOCOL=$(istioctl ztunnel-config workloads ${ZTUNNEL_POD}.ztunnel \
      --workload-namespace $NS 2>/dev/null | grep " ${APP}-" | head -1 | awk '{print $NF}')
    [[ "$PROTOCOL" == "HBONE" ]] \
      && pass "${NS}/${APP}: HBONE" \
      || fail "${NS}/${APP}: PROTOCOL=${PROTOCOL} (expected HBONE)"
  done
done

# =============================================================================
# SECTION 6 — Waypoints
# =============================================================================
section "Waypoints"

for TENANT in a b; do
  tenant "Tenant-${TENANT^^}"
  NS="bookinfo-${TENANT}"
  GW_NS="bookinfo-ingress-${TENANT}"

  # Waypoint pod
  WP_READY=$(oc get pods -n $NS -l "gateway.networking.k8s.io/gateway-name=waypoint" \
    --no-headers 2>/dev/null | awk '{print $2}')
  [[ "$WP_READY" == "1/1" ]] \
    && pass "${NS}/waypoint pod: 1/1 Running" \
    || fail "${NS}/waypoint pod: ${WP_READY}"

  # Gateway pod
  GW_READY=$(oc get pods -n $GW_NS --no-headers 2>/dev/null | grep "gateway" | grep "1/1" | wc -l)
  [[ "$GW_READY" -ge 1 ]] \
    && pass "${GW_NS}/gateway pod: Running" \
    || fail "${GW_NS}/gateway pod: not ready"

  # Waypoint attached to services
  for SVC in details productpage ratings reviews; do
    WAYPOINT=$(istioctl ztunnel-config svc --namespace ztunnel 2>/dev/null | \
      grep "${NS} " | grep " ${SVC} " | awk '{print $4}')
    [[ "$WAYPOINT" == "waypoint" ]] \
      && pass "${NS}/${SVC}: WAYPOINT=waypoint" \
      || fail "${NS}/${SVC}: WAYPOINT=${WAYPOINT} (expected waypoint)"
  done
done

# =============================================================================
# SECTION 7 — PeerAuthentication
# =============================================================================
section "PeerAuthentication (STRICT mTLS)"

MODE=$(oc get peerauthentication default -n istio-system \
  -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
[[ "$MODE" == "STRICT" ]] \
  && pass "Mesh-wide PeerAuthentication: STRICT" \
  || fail "Mesh-wide PeerAuthentication: ${MODE}"

for TENANT in a b; do
  MODE=$(oc get peerauthentication -n bookinfo-${TENANT} \
    -o jsonpath='{.items[0].spec.mtls.mode}' 2>/dev/null)
  [[ "$MODE" == "STRICT" ]] \
    && pass "bookinfo-${TENANT} PeerAuthentication: STRICT" \
    || fail "bookinfo-${TENANT} PeerAuthentication: ${MODE}"
done

# =============================================================================
# SECTION 8 — Ingress (AWS NLB)
# =============================================================================
section "Ingress gateway (AWS NLB)"

for TENANT in a b; do
  tenant "Tenant-${TENANT^^}"
  GW_NS="bookinfo-ingress-${TENANT}"

  # Gateway programmed
  GW_NAME="bookinfo-gateway-${TENANT}"
  PROGRAMMED=$(oc get gateway $GW_NAME -n $GW_NS \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  [[ "$PROGRAMMED" == "True" ]] \
    && pass "${GW_NS} Gateway: Programmed" \
    || fail "${GW_NS} Gateway: Programmed=${PROGRAMMED}"

  # Service type LoadBalancer (AWS)
  SVC_TYPE=$(oc get svc -n $GW_NS \
    -o jsonpath='{.items[0].spec.type}' 2>/dev/null)
  [[ "$SVC_TYPE" == "LoadBalancer" ]] \
    && pass "${GW_NS} Service: LoadBalancer (AWS NLB)" \
    || fail "${GW_NS} Service: type=${SVC_TYPE} (expected LoadBalancer on AWS)"

  # NLB hostname
  NLB=$(oc get svc -n $GW_NS \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [[ -n "$NLB" ]] \
    && pass "${GW_NS} NLB: ${NLB}" \
    || fail "${GW_NS} NLB: not provisioned"

  if [[ -n "$NLB" ]]; then
    # GET /productpage — expect 200
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout 10 "http://${NLB}/productpage" 2>/dev/null)
    [[ "$HTTP_CODE" == "200" ]] \
      && pass "${GW_NS} GET /productpage: 200 OK" \
      || fail "${GW_NS} GET /productpage: HTTP ${HTTP_CODE}"

    # POST /productpage — expect 403 (AuthorizationPolicy)
    HTTP_CODE=$(curl -s -X POST -o /dev/null -w "%{http_code}" \
      --connect-timeout 10 "http://${NLB}/productpage" 2>/dev/null)
    [[ "$HTTP_CODE" == "403" ]] \
      && pass "${GW_NS} POST /productpage: 403 (AuthorizationPolicy enforcing)" \
      || fail "${GW_NS} POST /productpage: HTTP ${HTTP_CODE} (expected 403)"
  fi
done

# =============================================================================
# SECTION 9 — AuthorizationPolicy (per tenant)
# =============================================================================
section "AuthorizationPolicy"

for TENANT in a b; do
  tenant "Tenant-${TENANT^^}"

  # Ingress policy
  ACTION=$(oc get authorizationpolicy -n bookinfo-ingress-${TENANT} \
    -o jsonpath='{.items[0].spec.action}' 2>/dev/null)
  [[ "$ACTION" == "ALLOW" ]] \
    && pass "bookinfo-ingress-${TENANT} AuthorizationPolicy: ALLOW" \
    || fail "bookinfo-ingress-${TENANT} AuthorizationPolicy: action=${ACTION}"

  # Productpage policy
  PP_ACTION=$(oc get authorizationpolicy -n bookinfo-${TENANT} \
    -o jsonpath='{.items[0].spec.action}' 2>/dev/null)
  [[ "$PP_ACTION" == "ALLOW" ]] \
    && pass "bookinfo-${TENANT} AuthorizationPolicy: ALLOW" \
    || fail "bookinfo-${TENANT} AuthorizationPolicy: action=${PP_ACTION}"
done

# =============================================================================
# SECTION 10 — Cross-tenant isolation
# =============================================================================
section "Cross-tenant isolation"

# Check curl-test pods exist and are running
for TENANT in a b; do
  CURL_PHASE=$(oc get pod curl-test -n bookinfo-${TENANT} \
    -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$CURL_PHASE" != "Running" ]]; then
    warn "curl-test pod not ready in bookinfo-${TENANT} (phase=${CURL_PHASE}) — skipping cross-tenant tests"
    warn "Deploy with: oc apply -f ~/service-mesh-3.2-multitenant/tenant-${TENANT}/namespaces/curl-test-${TENANT}.yaml"
    SKIP_CROSS=true
  fi
done

if [[ -z "$SKIP_CROSS" ]]; then
  # tenant-a → tenant-b GET (expect 403 — cross-tenant blocked)
  CODE=$(oc exec -n bookinfo-a curl-test -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://productpage.bookinfo-b.svc.cluster.local:9080/productpage 2>/dev/null)
  [[ "$CODE" == "403" ]] \
    && pass "Cross-tenant a→b GET: 403 (blocked)" \
    || fail "Cross-tenant a→b GET: ${CODE} (expected 403)"

  # tenant-b → tenant-a GET (expect 403 — cross-tenant blocked)
  CODE=$(oc exec -n bookinfo-b curl-test -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://productpage.bookinfo-a.svc.cluster.local:9080/productpage 2>/dev/null)
  [[ "$CODE" == "403" ]] \
    && pass "Cross-tenant b→a GET: 403 (blocked)" \
    || fail "Cross-tenant b→a GET: ${CODE} (expected 403)"

  # tenant-a → tenant-a GET (expect 200 — same tenant allowed)
  CODE=$(oc exec -n bookinfo-a curl-test -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://productpage.bookinfo-a.svc.cluster.local:9080/productpage 2>/dev/null)
  [[ "$CODE" == "200" ]] \
    && pass "Same-tenant a→a GET: 200 (allowed)" \
    || fail "Same-tenant a→a GET: ${CODE} (expected 200)"

  # tenant-b → tenant-b GET (expect 200 — same tenant allowed)
  CODE=$(oc exec -n bookinfo-b curl-test -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    http://productpage.bookinfo-b.svc.cluster.local:9080/productpage 2>/dev/null)
  [[ "$CODE" == "200" ]] \
    && pass "Same-tenant b→b GET: 200 (allowed)" \
    || fail "Same-tenant b→b GET: ${CODE} (expected 200)"
fi

# =============================================================================
# SECTION 11 — Distributed Tracing (Tempo + OTel)
# =============================================================================
section "Distributed Tracing (Tempo + OTel)"

# Tempo pods
TEMPO_READY=$(oc get pods -n tracing --no-headers 2>/dev/null | grep -c "1/1\|2/2\|3/3")
[[ "$TEMPO_READY" -ge 6 ]] \
  && pass "Tempo pods: ${TEMPO_READY} Running" \
  || fail "Tempo pods: only ${TEMPO_READY} ready (expected 6+)"

# TempoStack CR
TEMPO_STATUS=$(oc get tempostack tempo -n tracing \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[[ "$TEMPO_STATUS" == "True" ]] \
  && pass "TempoStack: Ready" \
  || fail "TempoStack: Ready=${TEMPO_STATUS}"

# Tempo tenants
for TENANT in tenant-a tenant-b; do
  T_NAME=$(oc get tempostack tempo -n tracing \
    -o jsonpath="{.spec.tenants.authentication[?(@.tenantName==\"${TENANT}\")].tenantName}" 2>/dev/null)
  [[ "$T_NAME" == "$TENANT" ]] \
    && pass "TempoStack tenant: ${TENANT} configured" \
    || fail "TempoStack tenant: ${TENANT} missing"
done

# OTel collector
OTEL=$(oc get pods -n tracing --no-headers 2>/dev/null | grep "otel-collector" | head -1 | awk '{print $2}')
[[ "$OTEL" == "1/1" ]] \
  && pass "otel-collector: 1/1 Running" \
  || fail "otel-collector: ${OTEL}"

# Telemetry CRs
TEL_MESH=$(oc get telemetry mesh-tracing -n istio-system --no-headers 2>/dev/null | wc -l)
[[ "$TEL_MESH" -ge 1 ]] \
  && pass "Telemetry CR: mesh-tracing (istio-system)" \
  || fail "Telemetry CR: mesh-tracing missing"

for TENANT in a b; do
  TEL=$(oc get telemetry waypoint-tracing-${TENANT} -n bookinfo-ingress-${TENANT} \
    --no-headers 2>/dev/null | wc -l)
  [[ "$TEL" -ge 1 ]] \
    && pass "Telemetry CR: waypoint-tracing-${TENANT} (bookinfo-ingress-${TENANT})" \
    || fail "Telemetry CR: waypoint-tracing-${TENANT} missing (required for waypoint tracing in ambient mode)"
done

# OTel cluster in waypoint xDS
for TENANT in a b; do
  GW_POD=$(oc get pods -n bookinfo-ingress-${TENANT} --no-headers 2>/dev/null \
    | grep gateway | grep "1/1" | awk '{print $1}' | head -1)
  if [[ -n "$GW_POD" ]]; then
    OTEL_CLUSTER=$(istioctl proxy-config cluster $GW_POD \
      -n bookinfo-ingress-${TENANT} 2>/dev/null | grep -c "otel-collector")
    [[ "$OTEL_CLUSTER" -ge 1 ]] \
      && pass "bookinfo-ingress-${TENANT} gateway: otel-collector cluster in xDS" \
      || fail "bookinfo-ingress-${TENANT} gateway: otel-collector cluster missing from xDS"
  fi
done

# UIPlugin
UI_AVAIL=$(oc get uiplugin distributed-tracing \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
[[ "$UI_AVAIL" == "True" ]] \
  && pass "UIPlugin distributed-tracing: Available" \
  || warn "UIPlugin distributed-tracing: Available=${UI_AVAIL}"

# S3 bucket reachable (check ingester flushed blocks)
BLOCKS=$(oc logs -n tracing tempo-tempo-ingester-0 --since=30m 2>/dev/null \
  | grep -c "flushing block")
[[ "$BLOCKS" -ge 1 ]] \
  && pass "Tempo ingester: trace blocks flushed to S3 (${BLOCKS} blocks)" \
  || warn "Tempo ingester: no blocks flushed recently (generate traffic first)"

# OTel collector pipeline — verify spans received and exported
OTEL_POD=$(oc get pods -n tracing --no-headers 2>/dev/null \
  | grep "otel-collector" | grep "1/1" | awk '{print $1}' | head -1)
if [[ -n "$OTEL_POD" ]]; then
  RECV=$(oc exec -n tracing $OTEL_POD -- \
    wget -q -O- http://localhost:8888/metrics 2>/dev/null \
    | grep "^otelcol_receiver_accepted_spans{" | awk '{sum+=$NF} END{print int(sum)}')
  [[ -n "$RECV" && "$RECV" -gt 0 ]] \
    && pass "OTel collector: ${RECV} total spans received" \
    || warn "OTel collector: 0 spans received (generate traffic then recheck)"

  for TNAME in tenant-a tenant-b; do
    SENT=$(oc exec -n tracing $OTEL_POD -- \
      wget -q -O- http://localhost:8888/metrics 2>/dev/null \
      | grep "^otelcol_exporter_sent_spans{" | grep "$TNAME" \
      | awk '{print int($NF)}' | head -1)
    [[ -n "$SENT" && "$SENT" -gt 0 ]] \
      && pass "OTel exporter → Tempo ${TNAME}: ${SENT} spans sent" \
      || warn "OTel exporter → Tempo ${TNAME}: 0 spans sent (generate traffic first)"
  done
else
  fail "OTel collector pod not found or not ready"
fi

# Metrics Telemetry — required for Kiali graph
# Kiali graph is empty if mesh-default metrics policy is missing
METRICS_PROVIDER=$(oc get istio default \
  -o jsonpath='{.spec.values.meshConfig.defaultProviders.metrics[0]}' 2>/dev/null)
[[ "$METRICS_PROVIDER" == "prometheus" ]] \
  && pass "meshConfig.defaultProviders.metrics: prometheus (Kiali graph enabled)" \
  || warn "meshConfig.defaultProviders.metrics: '${METRICS_PROVIDER}' (empty = Kiali graph may be blank)"

# Check Telemetry CR is not accidentally disabling metrics
TEL_METRICS=$(oc get telemetry -A -o json 2>/dev/null | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
disabled=[i['metadata']['namespace']+'/'+i['metadata']['name']
  for i in d['items']
  if any(m.get('disabled') for m in i.get('spec',{}).get('metrics',[]))]
print(','.join(disabled) if disabled else 'none')
" 2>/dev/null)
[[ "$TEL_METRICS" == "none" || -z "$TEL_METRICS" ]] \
  && pass "Telemetry CRs: no metrics disabled (Kiali graph safe)" \
  || warn "Telemetry CRs: metrics disabled in ${TEL_METRICS} (may blank Kiali graph)"

# =============================================================================
# SECTION 12 — Observability (Prometheus)
# =============================================================================
section "Observability (Prometheus)"

# User workload monitoring
UWM=$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null \
  | grep "prometheus-user-workload" | grep "6/6" | wc -l)
[[ "$UWM" -ge 1 ]] \
  && pass "prometheus-user-workload: Running" \
  || fail "prometheus-user-workload: not ready (check cluster-monitoring-config.yaml)"

# Kiali
KIALI_READY=$(oc get pods -n istio-system -l app=kiali \
  --no-headers 2>/dev/null | awk '{print $2}')
[[ "$KIALI_READY" == "1/1" ]] \
  && pass "Kiali pod: 1/1 Running" \
  || fail "Kiali pod: ${KIALI_READY}"

KIALI_ROUTE=$(oc get route kiali -n istio-system \
  -o jsonpath='{.spec.host}' 2>/dev/null)
[[ -n "$KIALI_ROUTE" ]] \
  && pass "Kiali route: https://${KIALI_ROUTE}" \
  || fail "Kiali route: not found"

# Kiali accessible namespaces
for NS in bookinfo-a bookinfo-ingress-a bookinfo-b bookinfo-ingress-b; do
  IN_LIST=$(oc get kiali kiali -n istio-system \
    -o jsonpath='{.spec.deployment.accessible_namespaces}' 2>/dev/null | grep -c "$NS")
  [[ "$IN_LIST" -ge 1 ]] \
    && pass "Kiali accessible_namespaces: ${NS}" \
    || fail "Kiali accessible_namespaces: ${NS} missing"
done

# =============================================================================
# SECTION 13 — Final connectivity smoke test
# =============================================================================
section "Final smoke test"

for TENANT in a b; do
  NLB=$(oc get svc -n bookinfo-ingress-${TENANT} \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [[ -n "$NLB" ]]; then
    CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout 10 "http://${NLB}/productpage" 2>/dev/null)
    [[ "$CODE" == "200" ]] \
      && pass "Tenant-${TENANT^^} NLB (${NLB}): GET 200" \
      || fail "Tenant-${TENANT^^} NLB (${NLB}): GET ${CODE}"
  fi
done

# =============================================================================
# SUMMARY
# =============================================================================
echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  SUMMARY${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  PASS: ${PASS}${NC}"
[[ $WARN -gt 0 ]] && echo -e "${YELLOW}  WARN: ${WARN}${NC}"
[[ $FAIL -gt 0 ]] && echo -e "${RED}  FAIL: ${FAIL}${NC}"
echo ""

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
  echo -e "${GREEN}All tests passed.${NC}"
  exit 0
elif [[ $FAIL -eq 0 ]]; then
  echo -e "${YELLOW}All tests passed with warnings. Review above.${NC}"
  exit 0
else
  echo -e "${RED}${FAIL} test(s) failed. Review output above.${NC}"
  exit 1
fi
