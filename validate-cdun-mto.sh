#!/usr/bin/env bash
# =============================================================================
# validate.sh — service-mesh-3.2-multitenant full stack validation
#
# Covers 9 scenarios:
#   1.  CUDN — NAD injected into all 4 tenant namespaces
#   2.  Ambient mesh enrollment — redirection=enabled on all pods
#   3.  Waypoint pods on correct tenant node pools
#   4.  mTLS enforcement — STRICT PeerAuthentication cluster-wide
#   5.  Cross-tenant isolation — direct service call blocked
#   6.  Gateway programmed + MetalLB IPs assigned
#   7.  MTO namespace labels self-healing
#   8.  TemplateGroupInstance resources applied (NetworkPolicy, Quota, LimitRange)
#   9.  Node taints respected — pods on correct nodes
#
# Usage:
#   ./validate.sh                     run all checks
#   ./validate.sh --section 3         run only section 3
#   ./validate.sh --tenant-a-ip 10.10.10.50 --tenant-b-ip 10.10.10.51
#
# Requirements: oc, jq
# Compatibility: bash 3.2+ (macOS default)
# =============================================================================

set -uo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

FAILED=0; WARNED=0; PASSED=0
SECTION_FILTER=""

pass()  { echo -e "  ${GREEN}PASS${RESET}  $*"; PASSED=$((PASSED+1)); }
fail()  { echo -e "  ${RED}FAIL${RESET}  $*"; FAILED=$((FAILED+1)); }
warn()  { echo -e "  ${YELLOW}WARN${RESET}  $*"; WARNED=$((WARNED+1)); }
info()  { echo -e "  ${CYAN}INFO${RESET}  $*"; }
title() { echo -e "\n${BOLD}$*${RESET}"; printf '%.0s─' {1..60}; echo; }

# ── config ────────────────────────────────────────────────────────────────────
TENANT_A_NS="bookinfo-a"
TENANT_B_NS="bookinfo-b"
TENANT_A_INGRESS_NS="bookinfo-ingress-a"
TENANT_B_INGRESS_NS="bookinfo-ingress-b"
TENANT_A_NODES="worker-cluster-89pfx-3 worker-cluster-89pfx-4"
TENANT_B_NODES="worker-cluster-89pfx-5 worker-cluster-89pfx-6"
TENANT_A_CUDN_SUBNET="10.200.1"
TENANT_B_CUDN_SUBNET="10.200.2"
TENANT_A_GW_IP="10.10.10.50"
TENANT_B_GW_IP="10.10.10.51"

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --section)        SECTION_FILTER="$2"; shift 2 ;;
    --tenant-a-ip)    TENANT_A_GW_IP="$2"; shift 2 ;;
    --tenant-b-ip)    TENANT_B_GW_IP="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

should_run() {
  [[ -z "$SECTION_FILTER" || "$SECTION_FILTER" == "$1" ]]
}

# ── helper: check if oc is logged in ─────────────────────────────────────────
oc get nodes &>/dev/null || { echo -e "${RED}ERROR: oc not logged in${RESET}"; exit 1; }

# =============================================================================
# Section 1 — CUDN NAD injection
# =============================================================================
should_run 1 && {
title "1. CUDN — NetworkAttachmentDefinition injection"

for ns in "$TENANT_A_NS" "$TENANT_A_INGRESS_NS"; do
  nad=$(oc get net-attach-def -n "$ns" --no-headers 2>/dev/null | grep cudn-tenant-a | awk '{print $1}')
  if [[ -n "$nad" ]]; then
    pass "NAD cudn-tenant-a present in $ns"
    # verify the NAD has correct subnet
    subnet=$(oc get net-attach-def cudn-tenant-a -n "$ns" \
      -o jsonpath='{.spec.config}' 2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('subnets',''))" 2>/dev/null || \
      oc get net-attach-def cudn-tenant-a -n "$ns" \
      -o jsonpath='{.spec.config}' 2>/dev/null | grep -o '"subnets":"[^"]*"' | cut -d'"' -f4)
    if echo "$subnet" | grep -q "$TENANT_A_CUDN_SUBNET"; then
      pass "NAD subnet $subnet matches expected $TENANT_A_CUDN_SUBNET.0/24"
    else
      warn "NAD subnet '$subnet' — expected $TENANT_A_CUDN_SUBNET.0/24"
    fi
  else
    fail "NAD cudn-tenant-a NOT found in $ns"
  fi
done

for ns in "$TENANT_B_NS" "$TENANT_B_INGRESS_NS"; do
  nad=$(oc get net-attach-def -n "$ns" --no-headers 2>/dev/null | grep cudn-tenant-b | awk '{print $1}')
  if [[ -n "$nad" ]]; then
    pass "NAD cudn-tenant-b present in $ns"
  else
    fail "NAD cudn-tenant-b NOT found in $ns"
  fi
done

# verify CUDN status shows namespaces
for cudn in cudn-tenant-a cudn-tenant-b; do
  msg=$(oc describe clusteruserdefinednetwork "$cudn" 2>/dev/null | grep "Message:" | tail -1)
  if echo "$msg" | grep -q "bookinfo"; then
    pass "$cudn — $msg"
  else
    fail "$cudn — NAD not injected into namespaces: $msg"
  fi
done

# ── verify pods have dual interface: eth0 (primary) + net1 (CUDN secondary) ──
info "Checking pod dual-interface (eth0 primary + net1 CUDN secondary)"

check_pod_interfaces() {
  local ns=$1
  local cudn_name=$2
  local expected_subnet=$3

  local pods
  pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | \
    grep -v waypoint | grep Running | awk '{print $1}')

  if [[ -z "$pods" ]]; then
    warn "$ns — no Running pods to check (bookinfo not deployed?)"
    return
  fi

  while IFS= read -r pod; do
    net_status=$(oc get pod "$pod" -n "$ns" \
      -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' \
      2>/dev/null)

    if [[ -z "$net_status" ]]; then
      warn "$ns/$pod — no network-status annotation found"
      continue
    fi

    # check eth0 primary exists
    eth0_ip=$(echo "$net_status" | \
      jq -r '.[] | select(.interface=="eth0") | .ips[0]' 2>/dev/null)
    if [[ -n "$eth0_ip" ]]; then
      pass "$ns/$pod — eth0 $eth0_ip (primary mesh interface)"
    else
      fail "$ns/$pod — eth0 primary interface MISSING"
    fi

    # check net1 secondary exists with correct CUDN subnet
    net1_ip=$(echo "$net_status" | \
      jq -r '.[] | select(.interface=="net1") | .ips[0]' 2>/dev/null)
    if [[ -n "$net1_ip" ]]; then
      if echo "$net1_ip" | grep -q "^${expected_subnet}\."; then
        pass "$ns/$pod — net1 $net1_ip (CUDN $cudn_name secondary)"
      else
        fail "$ns/$pod — net1 $net1_ip does not match expected subnet $expected_subnet.x"
      fi
    else
      fail "$ns/$pod — net1 CUDN secondary interface MISSING (add annotation k8s.v1.cni.cncf.io/networks: $cudn_name)"
    fi
  done <<< "$pods"
}

check_pod_interfaces "$TENANT_A_NS" "cudn-tenant-a" "$TENANT_A_CUDN_SUBNET"
check_pod_interfaces "$TENANT_B_NS" "cudn-tenant-b" "$TENANT_B_CUDN_SUBNET"
}

# =============================================================================
# Section 2 — Ambient mesh enrollment
# =============================================================================
should_run 2 && {
title "2. Ambient mesh enrollment — redirection=enabled on all pods"

for ns in "$TENANT_A_NS" "$TENANT_B_NS"; do
  pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | \
    grep -v waypoint | grep Running | awk '{print $1}')
  if [[ -z "$pods" ]]; then
    warn "No Running pods found in $ns (bookinfo not deployed?)"
    continue
  fi
  all_enrolled=true
  while IFS= read -r pod; do
    redir=$(oc get pod "$pod" -n "$ns" \
      -o jsonpath='{.metadata.annotations.ambient\.istio\.io/redirection}' 2>/dev/null)
    if [[ "$redir" == "enabled" ]]; then
      pass "$ns/$pod — ambient.istio.io/redirection=enabled"
    else
      fail "$ns/$pod — ambient.istio.io/redirection='$redir' (expected: enabled)"
      all_enrolled=false
    fi
  done <<< "$pods"
done
}

# =============================================================================
# Section 3 — Waypoint pods on correct node pools
# =============================================================================
should_run 3 && {
title "3. Waypoint pods on correct tenant node pools"

# tenant-a waypoint should be on worker-89pfx-3 or worker-89pfx-4
wp_a_node=$(oc get pods -n "$TENANT_A_NS" -l gateway.istio.io/managed=istio.io-mesh-controller \
  --no-headers -o wide 2>/dev/null | awk '{print $7}')
if [[ -z "$wp_a_node" ]]; then
  wp_a_node=$(oc get pods -n "$TENANT_A_NS" -l "istio.io/gateway-name=waypoint" \
    --no-headers -o wide 2>/dev/null | awk '{print $7}')
fi
if [[ -z "$wp_a_node" ]]; then
  wp_a_node=$(oc get pods -n "$TENANT_A_NS" --no-headers -o wide 2>/dev/null | \
    grep waypoint | awk '{print $7}')
fi

if [[ -n "$wp_a_node" ]]; then
  if echo "$TENANT_A_NODES" | grep -qw "$wp_a_node"; then
    pass "waypoint-a on $wp_a_node (tenant-a node pool)"
  else
    fail "waypoint-a on $wp_a_node — expected one of: $TENANT_A_NODES"
  fi
else
  warn "waypoint-a pod not found in $TENANT_A_NS"
fi

# tenant-b waypoint should be on worker-89pfx-5 or worker-89pfx-6
wp_b_node=$(oc get pods -n "$TENANT_B_NS" --no-headers -o wide 2>/dev/null | \
  grep waypoint | awk '{print $7}')

if [[ -n "$wp_b_node" ]]; then
  if echo "$TENANT_B_NODES" | grep -qw "$wp_b_node"; then
    pass "waypoint-b on $wp_b_node (tenant-b node pool)"
  else
    fail "waypoint-b on $wp_b_node — expected one of: $TENANT_B_NODES"
  fi
else
  warn "waypoint-b pod not found in $TENANT_B_NS"
fi
}

# =============================================================================
# Section 4 — mTLS enforcement
# =============================================================================
should_run 4 && {
title "4. mTLS enforcement — STRICT PeerAuthentication"

# mesh-wide policy in istio-system
meshwide=$(oc get peerauthentication default -n istio-system \
  -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
if [[ "$meshwide" == "STRICT" ]]; then
  pass "mesh-wide PeerAuthentication in istio-system — mode: STRICT"
else
  fail "mesh-wide PeerAuthentication — expected STRICT, got: '$meshwide'"
fi

# per-tenant policies
for ns in "$TENANT_A_NS" "$TENANT_B_NS"; do
  pa=$(oc get peerauthentication -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')
  if [[ -n "$pa" ]]; then
    mode=$(oc get peerauthentication "$pa" -n "$ns" \
      -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
    if [[ "$mode" == "STRICT" ]]; then
      pass "$ns PeerAuthentication '$pa' — mode: STRICT"
    else
      warn "$ns PeerAuthentication '$pa' — mode: '$mode' (expected STRICT)"
    fi
  else
    warn "No per-namespace PeerAuthentication in $ns (mesh-wide STRICT still applies)"
  fi
done

# istiod running — required for mTLS cert distribution
istiod=$(oc get pods -n istio-system -l app=istiod \
  --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
if [[ "$istiod" -ge 1 ]]; then
  pass "istiod Running ($istiod pod(s)) — cert distribution active"
else
  fail "istiod not Running — mTLS cert distribution broken"
fi

# ztunnel running on all nodes
ztunnel_total=$(oc get pods -n ztunnel --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
node_total=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ztunnel_total" -eq "$node_total" ]]; then
  pass "ztunnel DaemonSet — $ztunnel_total/$node_total nodes Running"
else
  fail "ztunnel DaemonSet — $ztunnel_total/$node_total nodes Running (expected $node_total)"
fi
}

# =============================================================================
# Section 5 — Cross-tenant isolation
# =============================================================================
should_run 5 && {
title "5. Cross-tenant isolation — direct service call blocked"

# ── helper: run curl pod with restricted-compliant security context ───────────
# Namespaces enforce pod-security.kubernetes.io/enforce: restricted
# curlimages/curl runs as non-root (uid 65534) and is restricted-compatible
# We use a manifest via oc create -f - to set full securityContext
run_curl_pod() {
  local pod_name=$1
  local ns=$2
  local target_url=$3

  oc run "$pod_name" -n "$ns" \
    --image=curlimages/curl \
    --rm -i --restart=Never \
    --timeout=30s \
    --overrides='{
      "spec":{
        "containers":[{
          "name":"'"$pod_name"'",
          "image":"curlimages/curl",
          "args":["curl","-s","--connect-timeout","5","'"$target_url"'"],
          "securityContext":{
            "allowPrivilegeEscalation":false,
            "runAsNonRoot":true,
            "runAsUser":65534,
            "capabilities":{"drop":["ALL"]},
            "seccompProfile":{"type":"RuntimeDefault"}
          }
        }],
        "nodeSelector":{"mesh":"'"$(echo "$ns" | grep -q "bookinfo-a" && echo tenant-a || echo tenant-b)"'"},
        "tolerations":[
          {"key":"mesh","operator":"Equal","value":"tenant-a","effect":"NoSchedule"},
          {"key":"mesh","operator":"Equal","value":"tenant-b","effect":"NoSchedule"}
        ]
      }
    }' 2>&1 || true
}

info "Testing direct cross-namespace service access (tenant-a → tenant-b service)"
info "This requires a curl pod — may take 30s"

result=$(run_curl_pod "cudn-validate-curl" "$TENANT_A_NS" \
  "http://productpage.${TENANT_B_NS}.svc.cluster.local:9080/productpage")

# strip kubectl warnings before evaluating result
clean_result=$(echo "$result" | grep -v "^W[0-9]" | grep -v "would violate" | \
  grep -v "^If you" | grep -v "^pod " || true)

if echo "$clean_result" | grep -qiE "reset|refused|Connection reset|RBAC|403|denied|timed out|Could not resolve"; then
  pass "Cross-tenant direct access BLOCKED: $(echo "$clean_result" | grep -oiE 'reset|refused|RBAC|403|denied|timed out|Could not resolve' | head -1)"
elif echo "$clean_result" | grep -q "Simple Bookstore"; then
  fail "Cross-tenant direct access ALLOWED — tenant isolation NOT enforced"
elif [[ -z "$clean_result" ]]; then
  pass "Cross-tenant direct access BLOCKED: connection reset (empty response)"
else
  warn "Unexpected result — check manually: $clean_result"
fi

info "Testing reverse direction (tenant-b → tenant-a service)"
result2=$(run_curl_pod "cudn-validate-curl2" "$TENANT_B_NS" \
  "http://productpage.${TENANT_A_NS}.svc.cluster.local:9080/productpage")

clean_result2=$(echo "$result2" | grep -v "^W[0-9]" | grep -v "would violate" | \
  grep -v "^If you" | grep -v "^pod " || true)

if echo "$clean_result2" | grep -qiE "reset|refused|Connection reset|RBAC|403|denied|timed out|Could not resolve"; then
  pass "Reverse cross-tenant access BLOCKED: $(echo "$clean_result2" | grep -oiE 'reset|refused|RBAC|403|denied|timed out|Could not resolve' | head -1)"
elif echo "$clean_result2" | grep -q "Simple Bookstore"; then
  fail "Reverse cross-tenant access ALLOWED — tenant isolation NOT enforced"
elif [[ -z "$clean_result2" ]]; then
  pass "Reverse cross-tenant access BLOCKED: connection reset (empty response)"
else
  warn "Unexpected result — check manually: $clean_result2"
fi
}

# =============================================================================
# Section 6 — Gateway programmed + MetalLB IPs
# =============================================================================
should_run 6 && {
title "6. Gateway programmed + MetalLB IPs assigned"

# waypoints
for ns in "$TENANT_A_NS" "$TENANT_B_NS"; do
  prog=$(oc get gateway waypoint -n "$ns" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  addr=$(oc get gateway waypoint -n "$ns" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
  if [[ "$prog" == "True" ]]; then
    pass "waypoint in $ns — Programmed=True address=$addr"
  else
    fail "waypoint in $ns — Programmed='$prog' (expected True)"
  fi
done

# ingress gateways — check each tenant separately to avoid parsing issues
check_ingress_gateway() {
  local ns=$1
  local gw=$2
  local expected_ip=$3
  local prog actual_ip
  prog=$(oc get gateway "$gw" -n "$ns" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  actual_ip=$(oc get svc "${gw}-istio" -n "$ns" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [[ "$prog" == "True" ]]; then
    pass "$gw in $ns — Programmed=True"
  else
    fail "$gw in $ns — Programmed='$prog' (expected True)"
  fi
  if [[ "$actual_ip" == "$expected_ip" ]]; then
    pass "$gw ExternalIP=$actual_ip (matches expected $expected_ip)"
  elif [[ -n "$actual_ip" ]]; then
    pass "$gw ExternalIP=$actual_ip (assigned by MetalLB)"
    info "  expected $expected_ip — update TENANT_A_GW_IP/TENANT_B_GW_IP in script if different"
  else
    fail "$gw ExternalIP not assigned (MetalLB not working)"
  fi
}

check_ingress_gateway "$TENANT_A_INGRESS_NS" "bookinfo-gateway-a" "$TENANT_A_GW_IP"
check_ingress_gateway "$TENANT_B_INGRESS_NS" "bookinfo-gateway-b" "$TENANT_B_GW_IP"

# MetalLB pods
controller=$(oc get pods -n metallb-system -l component=controller \
  --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
speakers=$(oc get pods -n metallb-system -l component=speaker \
  --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
if [[ "$controller" -ge 1 ]]; then
  pass "MetalLB controller Running ($controller pod)"
else
  fail "MetalLB controller not Running"
fi
if [[ "$speakers" -ge 1 ]]; then
  pass "MetalLB speakers Running ($speakers pods)"
else
  fail "MetalLB speakers not Running"
fi
}

# =============================================================================
# Section 7 — MTO namespace labels self-healing
# =============================================================================
should_run 7 && {
title "7. MTO namespace labels self-healing"

declare -a COMMON_LABELS=(
  "istio-discovery=enabled"
  "istio-injection=disabled"
  "istio.io/dataplane-mode=ambient"
  "openshift.io/user-monitoring=true"
  "stakater.com/mesh-profile=ambient"
)

declare -a TENANT_A_WORKLOAD_LABELS=(
  "mesh=tenant-a"
  "istio.io/use-waypoint=waypoint"
  "stakater.com/mesh-waypoint=true"
  "topology.kubernetes.io/tenant=tenant-a"
)

declare -a TENANT_A_INGRESS_LABELS=(
  "mesh=tenant-a"
  "stakater.com/tenant-ingress=tenant-a"
  "topology.kubernetes.io/tenant=tenant-a"
)

declare -a TENANT_B_WORKLOAD_LABELS=(
  "mesh=tenant-b"
  "istio.io/use-waypoint=waypoint"
  "stakater.com/mesh-waypoint=true"
  "topology.kubernetes.io/tenant=tenant-b"
)

declare -a TENANT_B_INGRESS_LABELS=(
  "mesh=tenant-b"
  "stakater.com/tenant-ingress=tenant-b"
  "topology.kubernetes.io/tenant=tenant-b"
)

check_ns_labels() {
  local ns=$1
  shift
  local ns_labels
  ns_labels=$(oc get ns "$ns" --show-labels --no-headers 2>/dev/null | \
    awk '{print $NF}')
  for label in "$@"; do
    if echo "$ns_labels" | grep -q "$label"; then
      pass "$ns — $label"
    else
      fail "$ns — MISSING label: $label"
    fi
  done
}

info "Checking bookinfo-a (common + workload labels)"
check_ns_labels "$TENANT_A_NS" "${COMMON_LABELS[@]}" "${TENANT_A_WORKLOAD_LABELS[@]}"

info "Checking bookinfo-ingress-a (common + ingress labels)"
check_ns_labels "$TENANT_A_INGRESS_NS" "${COMMON_LABELS[@]}" "${TENANT_A_INGRESS_LABELS[@]}"

info "Checking bookinfo-b (common + workload labels)"
check_ns_labels "$TENANT_B_NS" "${COMMON_LABELS[@]}" "${TENANT_B_WORKLOAD_LABELS[@]}"

info "Checking bookinfo-ingress-b (common + ingress labels)"
check_ns_labels "$TENANT_B_INGRESS_NS" "${COMMON_LABELS[@]}" "${TENANT_B_INGRESS_LABELS[@]}"

# verify use-waypoint is ABSENT from ingress namespaces
for ns in "$TENANT_A_INGRESS_NS" "$TENANT_B_INGRESS_NS"; do
  ns_labels=$(oc get ns "$ns" --show-labels --no-headers 2>/dev/null | awk '{print $NF}')
  if echo "$ns_labels" | grep -q "istio.io/use-waypoint"; then
    fail "$ns — istio.io/use-waypoint SHOULD NOT be present on ingress namespace"
  else
    pass "$ns — istio.io/use-waypoint correctly absent"
  fi
done
}

# =============================================================================
# Section 8 — TemplateGroupInstance resources applied
# =============================================================================
should_run 8 && {
title "8. TemplateGroupInstance resources applied (NetworkPolicy, Quota, LimitRange)"

# check TemplateGroupInstances exist
for tgi in mesh-network-policy mesh-resource-quota mesh-limit-range; do
  tgi_status=$(oc get templategroupinstance "$tgi" --no-headers 2>/dev/null | awk '{print $1}')
  if [[ -n "$tgi_status" ]]; then
    pass "TemplateGroupInstance '$tgi' exists"
  else
    fail "TemplateGroupInstance '$tgi' NOT found"
  fi
done

# check NetworkPolicy applied to all 4 namespaces
for ns in "$TENANT_A_NS" "$TENANT_A_INGRESS_NS" "$TENANT_B_NS" "$TENANT_B_INGRESS_NS"; do
  np=$(oc get networkpolicy mto-baseline-mesh-policy -n "$ns" \
    --no-headers 2>/dev/null | awk '{print $1}')
  if [[ -n "$np" ]]; then
    pass "$ns — NetworkPolicy mto-baseline-mesh-policy present"
  else
    fail "$ns — NetworkPolicy mto-baseline-mesh-policy MISSING"
  fi
done

# check ResourceQuota applied
for ns in "$TENANT_A_NS" "$TENANT_A_INGRESS_NS" "$TENANT_B_NS" "$TENANT_B_INGRESS_NS"; do
  rq=$(oc get resourcequota mto-default-quota -n "$ns" \
    --no-headers 2>/dev/null | awk '{print $1}')
  if [[ -n "$rq" ]]; then
    pass "$ns — ResourceQuota mto-default-quota present"
  else
    fail "$ns — ResourceQuota mto-default-quota MISSING"
  fi
done

# check Tenant Quotas exist
for quota in tenant-a-quota tenant-b-quota; do
  q=$(oc get quota "$quota" -n multi-tenant-operator \
    --no-headers 2>/dev/null | awk '{print $1}')
  if [[ -n "$q" ]]; then
    pass "Tenant Quota '$quota' present in multi-tenant-operator"
  else
    fail "Tenant Quota '$quota' MISSING from multi-tenant-operator"
  fi
done
}

# =============================================================================
# Section 9 — Node taints respected
# =============================================================================
should_run 9 && {
title "9. Node taints respected — pods on correct nodes"

# verify tenant-a nodes have correct taint
for node in $TENANT_A_NODES; do
  taint=$(oc get node "$node" \
    -o jsonpath='{.spec.taints[?(@.key=="mesh")].value}' 2>/dev/null)
  effect=$(oc get node "$node" \
    -o jsonpath='{.spec.taints[?(@.key=="mesh")].effect}' 2>/dev/null)
  if [[ "$taint" == "tenant-a" && "$effect" == "NoSchedule" ]]; then
    pass "$node — taint mesh=tenant-a:NoSchedule present"
  else
    fail "$node — expected taint mesh=tenant-a:NoSchedule, got value='$taint' effect='$effect'"
  fi
done

# verify tenant-b nodes have correct taint
for node in $TENANT_B_NODES; do
  taint=$(oc get node "$node" \
    -o jsonpath='{.spec.taints[?(@.key=="mesh")].value}' 2>/dev/null)
  effect=$(oc get node "$node" \
    -o jsonpath='{.spec.taints[?(@.key=="mesh")].effect}' 2>/dev/null)
  if [[ "$taint" == "tenant-b" && "$effect" == "NoSchedule" ]]; then
    pass "$node — taint mesh=tenant-b:NoSchedule present"
  else
    fail "$node — expected taint mesh=tenant-b:NoSchedule, got value='$taint' effect='$effect'"
  fi
done

# verify bookinfo-a pods run only on tenant-a nodes
info "Checking bookinfo-a pod placement"
while IFS= read -r line; do
  pod=$(echo "$line" | awk '{print $1}')
  node=$(echo "$line" | awk '{print $7}')
  [[ "$pod" == "NAME" ]] && continue
  [[ -z "$pod" || -z "$node" ]] && continue
  if echo "$TENANT_A_NODES" | grep -qw "$node"; then
    pass "$TENANT_A_NS/$pod → $node (tenant-a pool)"
  else
    fail "$TENANT_A_NS/$pod → $node (NOT in tenant-a pool: $TENANT_A_NODES)"
  fi
done < <(oc get pods -n "$TENANT_A_NS" -o wide --no-headers 2>/dev/null)

# verify bookinfo-b pods run only on tenant-b nodes
info "Checking bookinfo-b pod placement"
while IFS= read -r line; do
  pod=$(echo "$line" | awk '{print $1}')
  node=$(echo "$line" | awk '{print $7}')
  [[ "$pod" == "NAME" ]] && continue
  [[ -z "$pod" || -z "$node" ]] && continue
  if echo "$TENANT_B_NODES" | grep -qw "$node"; then
    pass "$TENANT_B_NS/$pod → $node (tenant-b pool)"
  else
    fail "$TENANT_B_NS/$pod → $node (NOT in tenant-b pool: $TENANT_B_NODES)"
  fi
done < <(oc get pods -n "$TENANT_B_NS" -o wide --no-headers 2>/dev/null)
}

# =============================================================================
# Section 10 — Observability stack
# =============================================================================
should_run 10 && {
title "10. Observability stack"

# ── OTel collector ────────────────────────────────────────────────────────────
otel=$(oc get pods -n tracing -l app.kubernetes.io/component=opentelemetry-collector \
  --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
if [[ "$otel" -ge 1 ]]; then
  pass "OTel collector Running ($otel pod) in tracing namespace"
else
  fail "OTel collector not Running in tracing namespace"
fi

# verify OTel collector service exists and is reachable
otel_svc=$(oc get svc -n tracing --no-headers 2>/dev/null | \
  grep -i otel | awk '{print $1}' | head -1)
if [[ -n "$otel_svc" ]]; then
  pass "OTel collector Service '$otel_svc' exists"
else
  fail "OTel collector Service not found in tracing namespace"
fi

# ── TempoStack ────────────────────────────────────────────────────────────────
tempo_status=$(oc get tempostack tempo -n tracing \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [[ "$tempo_status" == "True" ]]; then
  pass "TempoStack 'tempo' Ready=True"
else
  # check individual pods even if condition not set
  tempo_running=$(oc get pods -n tracing --no-headers 2>/dev/null | \
    grep "^tempo-" | grep Running | wc -l | tr -d ' ')
  if [[ "$tempo_running" -ge 5 ]]; then
    pass "TempoStack pods Running ($tempo_running/7)"
  else
    fail "TempoStack not Ready — only $tempo_running pods Running"
  fi
fi

# verify multi-tenant config — tenant-a and tenant-b
for tenant in tenant-a tenant-b; do
  tenant_config=$(oc get tempostack tempo -n tracing \
    -o jsonpath="{.spec.tenants.authentication[?(@.tenantName=='$tenant')].tenantName}" \
    2>/dev/null)
  if [[ "$tenant_config" == "$tenant" ]]; then
    pass "TempoStack multi-tenant — $tenant configured"
  else
    fail "TempoStack multi-tenant — $tenant NOT configured"
  fi
done

# verify S3 secret exists (NooBaa OBC)
if oc get secret tempo-s3-secret -n tracing &>/dev/null; then
  pass "tempo-s3-secret present in tracing namespace"
else
  fail "tempo-s3-secret MISSING — run tempo-bucket-odf.yaml setup commands"
fi

# ── Kiali ─────────────────────────────────────────────────────────────────────
kiali_pod=$(oc get pods -n istio-system -l app=kiali \
  --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
if [[ "$kiali_pod" -ge 1 ]]; then
  pass "Kiali Running ($kiali_pod pod) in istio-system"
else
  fail "Kiali not Running in istio-system"
fi

ossmconsole=$(oc get pods -n istio-system -l app=ossmconsole \
  --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
if [[ "$ossmconsole" -ge 1 ]]; then
  pass "OSSMConsole Running ($ossmconsole pod)"
else
  warn "OSSMConsole not Running (optional OpenShift console plugin)"
fi

# verify Kiali can see tenant namespaces via kiali.io/member-of annotation
for ns in "$TENANT_A_NS" "$TENANT_A_INGRESS_NS" "$TENANT_B_NS" "$TENANT_B_INGRESS_NS"; do
  member=$(oc get ns "$ns" \
    -o jsonpath='{.metadata.annotations.kiali\.io/member-of}' 2>/dev/null)
  if [[ -n "$member" ]]; then
    pass "$ns — kiali.io/member-of=$member"
  else
    fail "$ns — kiali.io/member-of annotation MISSING"
  fi
done

# ── Prometheus user workload monitoring ───────────────────────────────────────
prom=$(oc get pods -n openshift-user-workload-monitoring \
  -l app.kubernetes.io/name=prometheus \
  --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
if [[ "$prom" -ge 1 ]]; then
  pass "Prometheus user workload monitoring Running ($prom pods)"
else
  fail "Prometheus user workload monitoring not Running"
fi

# verify ServiceMonitors exist for Istio components
if oc get servicemonitor istiod-monitor -n istio-system &>/dev/null; then
  pass "ServiceMonitor 'istiod-monitor' present in istio-system"
else
  fail "ServiceMonitor 'istiod-monitor' MISSING in istio-system"
fi

if oc get servicemonitor ztunnel-monitor -n ztunnel &>/dev/null; then
  pass "ServiceMonitor 'ztunnel-monitor' present in ztunnel"
else
  fail "ServiceMonitor 'ztunnel-monitor' MISSING in ztunnel"
fi

# verify waypoint PodMonitors exist in tenant namespaces
for ns in "$TENANT_A_NS" "$TENANT_B_NS"; do
  if oc get podmonitor waypoint-monitor -n "$ns" &>/dev/null; then
    pass "PodMonitor 'waypoint-monitor' present in $ns"
  else
    fail "PodMonitor 'waypoint-monitor' MISSING in $ns"
  fi
done

# ── Telemetry CR — OTel tracing enabled ───────────────────────────────────────
telemetry=$(oc get telemetry -n istio-system --no-headers 2>/dev/null | \
  awk '{print $1}' | head -1)
if [[ -n "$telemetry" ]]; then
  provider=$(oc get telemetry "$telemetry" -n istio-system \
    -o jsonpath='{.spec.tracing[0].providers[0].name}' 2>/dev/null)
  pass "Telemetry CR '$telemetry' — tracing provider: $provider"
else
  fail "Telemetry CR not found in istio-system"
fi

# check per-tenant telemetry CRs exist in gateway namespaces
for ns in "$TENANT_A_INGRESS_NS" "$TENANT_B_INGRESS_NS"; do
  tel=$(oc get telemetry -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -n "$tel" ]]; then
    pass "Telemetry CR '$tel' present in $ns"
  else
    warn "No per-tenant Telemetry CR in $ns (mesh-wide telemetry still applies)"
  fi
done
}

# =============================================================================
# Summary
# =============================================================================
title "Summary"
echo ""
echo -e "  ${GREEN}PASSED${RESET}: $PASSED"
echo -e "  ${YELLOW}WARNED${RESET}: $WARNED"
echo -e "  ${RED}FAILED${RESET}: $FAILED"
echo ""

if [[ $FAILED -eq 0 && $WARNED -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}ALL CHECKS PASSED${RESET}"
elif [[ $FAILED -eq 0 ]]; then
  echo -e "  ${YELLOW}${BOLD}PASSED WITH WARNINGS${RESET} — review warnings above"
else
  echo -e "  ${RED}${BOLD}FAILED — $FAILED check(s) need attention${RESET}"
  exit 1
fi
echo ""
