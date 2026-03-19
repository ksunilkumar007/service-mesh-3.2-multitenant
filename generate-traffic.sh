#!/usr/bin/env bash
# =============================================================================
# generate-traffic.sh
#
# Sends continuous traffic to both tenant gateways to populate
# the Kiali service graph and Tempo distributed traces.
#
# Usage:
#   ./generate-traffic.sh                    # default: 60s, both tenants
#   ./generate-traffic.sh --duration 300     # 5 minutes
#   ./generate-traffic.sh --tenant a         # tenant-a only
#   ./generate-traffic.sh --rps 5            # 5 requests/sec
#
# Requirements: oc
# =============================================================================

set -uo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info() { echo -e "  ${CYAN}INFO${RESET}  $*"; }
pass() { echo -e "  ${GREEN}PASS${RESET}  $*"; }

# ── defaults ─────────────────────────────────────────────────────────────────
DURATION=60
TENANT="both"
RPS=2
TENANT_A_GW="10.10.10.50"
TENANT_B_GW="10.10.10.51"

while [[ $# -gt 0 ]]; do
  case $1 in
    --duration) DURATION="$2"; shift 2 ;;
    --tenant)   TENANT="$2";   shift 2 ;;
    --rps)      RPS="$2";      shift 2 ;;
    --gw-a)     TENANT_A_GW="$2"; shift 2 ;;
    --gw-b)     TENANT_B_GW="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

SLEEP_INTERVAL=$(echo "scale=2; 1 / $RPS" | bc 2>/dev/null || echo "0.5")

# ── URLs to hit — exercises all bookinfo services ────────────────────────────
PATHS=(
  "/productpage"
  "/productpage?u=normal"
  "/productpage?u=test"
)

echo ""
echo -e "${BOLD}Traffic Generator — Kiali + Tempo${RESET}"
echo -e "Duration  : ${DURATION}s"
echo -e "Rate      : ${RPS} req/s"
echo -e "Tenant    : ${TENANT}"
echo -e "Gateway-a : ${TENANT_A_GW}"
echo -e "Gateway-b : ${TENANT_B_GW}"
echo ""

# ── build target list ────────────────────────────────────────────────────────
TARGETS=()
if [[ "$TENANT" == "a" || "$TENANT" == "both" ]]; then
  for path in "${PATHS[@]}"; do
    TARGETS+=("a:http://${TENANT_A_GW}${path}")
  done
fi
if [[ "$TENANT" == "b" || "$TENANT" == "both" ]]; then
  for path in "${PATHS[@]}"; do
    TARGETS+=("b:http://${TENANT_B_GW}${path}")
  done
fi

# ── run curl pod as background job ───────────────────────────────────────────
# Uses oc debug on a worker node to avoid PodSecurity restrictions
# and to ensure traffic originates from inside the cluster

WORKER_NODE="worker-cluster-89pfx-1"

info "Starting traffic generation via $WORKER_NODE for ${DURATION}s..."
info "Open Kiali → Graph → select bookinfo-a and bookinfo-b namespaces"
info "Set time range to 'Last 1m' and enable 'Traffic Animation'"
echo ""

END_TIME=$(( $(date +%s) + DURATION ))
REQUEST_COUNT=0
ERROR_COUNT=0
IDX=0

while [[ $(date +%s) -lt $END_TIME ]]; do
  # cycle through targets
  target="${TARGETS[$IDX]}"
  tenant_label=$(echo "$target" | cut -d: -f1)
  url=$(echo "$target" | cut -d: -f2-)

  # fire request via node debug
  response=$(oc debug "node/$WORKER_NODE" -- \
    chroot /host curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 "$url" 2>/dev/null || echo "000")

  REQUEST_COUNT=$(( REQUEST_COUNT + 1 ))

  if [[ "$response" == "200" ]]; then
    echo -e "  ${GREEN}200${RESET}  tenant-${tenant_label}  $url"
  elif [[ "$response" == "000" ]]; then
    ERROR_COUNT=$(( ERROR_COUNT + 1 ))
    echo -e "  \033[0;31mERR\033[0m  tenant-${tenant_label}  $url  (connection failed)"
  else
    echo -e "  \033[1;33m${response}\033[0m  tenant-${tenant_label}  $url"
  fi

  # advance target index
  IDX=$(( (IDX + 1) % ${#TARGETS[@]} ))

  sleep "$SLEEP_INTERVAL"
done

echo ""
echo -e "${BOLD}Traffic generation complete${RESET}"
echo -e "  Total requests : $REQUEST_COUNT"
echo -e "  Errors         : $ERROR_COUNT"
echo -e "  Success rate   : $(( (REQUEST_COUNT - ERROR_COUNT) * 100 / REQUEST_COUNT ))%"
echo ""
echo "Check Kiali:"
echo "  oc get route kiali -n istio-system -o jsonpath='{.spec.host}'"
echo ""
echo "Check Tempo traces:"
echo "  Kiali → Distributed Tracing → select tenant-a or tenant-b"
