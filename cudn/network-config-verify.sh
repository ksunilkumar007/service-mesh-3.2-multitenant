#!/bin/bash
# =============================================================================
# network-config-verify.sh
#
# Pre-flight validation before applying CUDN manifests.
# Checks proposed CUDN subnets do not conflict with:
#   1. clusterNetwork (pod primary CIDR)
#   2. serviceNetwork (ClusterIP range)
#   3. OVN-K internal range (100.64.0.0/16)
#   4. Node host IPs
#   5. Existing routes on tenant worker nodes
#   6. Existing CUDN / UDN objects in the cluster
#   7. OVN-K feature gate
#
# Usage:
#   ./network-config-verify.sh
#   ./network-config-verify.sh --subnets 10.200.1.0/24,10.200.2.0/24
#
# Requirements : oc, jq
# Compatibility: bash 3.2+ (macOS default) and bash 4/5 (Linux)
# =============================================================================

# -u: unbound vars are errors. NOT using -e so we collect all failures.
set -uo pipefail

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

FAILED=0; WARNED=0

pass()  { echo -e "  ${GREEN}PASS${RESET}  $*"; }
fail()  { echo -e "  ${RED}FAIL${RESET}  $*"; FAILED=$(( FAILED + 1 )); }
warn()  { echo -e "  ${YELLOW}WARN${RESET}  $*"; WARNED=$(( WARNED + 1 )); }
info()  { echo -e "  ${CYAN}INFO${RESET}  $*"; }
title() { echo -e "\n${BOLD}$*${RESET}"; printf '%.0s─' {1..60}; echo; }

# ── defaults — override with --subnets a,b ────────────────────────────────────
CUDN_SUBNET_A="10.200.1.0/24"
CUDN_SUBNET_B="10.200.2.0/24"

while [[ $# -gt 0 ]]; do
  case $1 in
    --subnets)
      CUDN_SUBNET_A=$(echo "$2" | cut -d, -f1)
      CUDN_SUBNET_B=$(echo "$2" | cut -d, -f2)
      shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

CUDN_SUBNETS=("$CUDN_SUBNET_A" "$CUDN_SUBNET_B")

# ── tenant worker nodes ───────────────────────────────────────────────────────
TENANT_NODES=(
  worker-cluster-89pfx-3
  worker-cluster-89pfx-4
  worker-cluster-89pfx-5
  worker-cluster-89pfx-6
)

OVN_INTERNAL="100.64.0.0/16"

# =============================================================================
# Pure-bash CIDR math — no ipcalc needed, works on bash 3.2
# =============================================================================
cidr_to_range() {
  local ip prefix
  ip=$(echo "$1"     | cut -d/ -f1)
  prefix=$(echo "$1" | cut -d/ -f2)
  local a b c d
  a=$(echo "$ip" | cut -d. -f1)
  b=$(echo "$ip" | cut -d. -f2)
  c=$(echo "$ip" | cut -d. -f3)
  d=$(echo "$ip" | cut -d. -f4)
  local ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
  local mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  local first=$(( ip_int & mask ))
  local last=$(( first + (1 << (32 - prefix)) - 1 ))
  echo "$first $last"
}

cidrs_overlap() {
  local r1 r2 f1 l1 f2 l2
  r1=$(cidr_to_range "$1"); r2=$(cidr_to_range "$2")
  f1=$(echo "$r1" | awk '{print $1}'); l1=$(echo "$r1" | awk '{print $2}')
  f2=$(echo "$r2" | awk '{print $1}'); l2=$(echo "$r2" | awk '{print $2}')
  [[ $f1 -le $l2 && $f2 -le $l1 ]]
}

ip_in_cidr() {
  local a b c d
  a=$(echo "$1" | cut -d. -f1)
  b=$(echo "$1" | cut -d. -f2)
  c=$(echo "$1" | cut -d. -f3)
  d=$(echo "$1" | cut -d. -f4)
  local ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
  local r f l
  r=$(cidr_to_range "$2")
  f=$(echo "$r" | awk '{print $1}')
  l=$(echo "$r" | awk '{print $2}')
  [[ $ip_int -ge $f && $ip_int -le $l ]]
}

# =============================================================================
# 1. Cluster network config
# =============================================================================
title "1. Cluster network configuration"

CLUSTER_SPEC=$(oc get network.config cluster -o json 2>/dev/null) || {
  fail "cannot reach cluster — is 'oc' logged in?"
  exit 1
}

# bash 3.2 safe array building with while-read
CLUSTER_NETWORKS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && CLUSTER_NETWORKS+=("$line")
done < <(echo "$CLUSTER_SPEC" | jq -r '.spec.clusterNetwork[].cidr')

SERVICE_NETWORKS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SERVICE_NETWORKS+=("$line")
done < <(echo "$CLUSTER_SPEC" | jq -r '.spec.serviceNetwork[]')

NETWORK_TYPE=$(echo "$CLUSTER_SPEC" | jq -r '.spec.networkType')

info "networkType    : $NETWORK_TYPE"
for cn in "${CLUSTER_NETWORKS[@]}"; do info "clusterNetwork : $cn"; done
for sn in "${SERVICE_NETWORKS[@]}"; do info "serviceNetwork : $sn"; done
info "OVN-K internal : $OVN_INTERNAL (always reserved)"
echo ""
[[ "$NETWORK_TYPE" != "OVNKubernetes" ]] && \
  warn "networkType is '$NETWORK_TYPE' — CUDN requires OVNKubernetes" || \
  pass "networkType is OVNKubernetes"

# =============================================================================
# 2. Node IPs
# =============================================================================
title "2. Node host IPs"

NODE_IPS=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  ip=$(echo "$line"   | awk '{print $6}')
  NODE_IPS+=("$ip")
  info "$name  →  $ip"
done < <(oc get nodes -o wide --no-headers 2>/dev/null)

# =============================================================================
# 3. Conflict check
# =============================================================================
title "3. Conflict check — proposed CUDN subnets"

for subnet in "${CUDN_SUBNETS[@]}"; do
  echo ""
  info "Checking $subnet"

  # vs clusterNetwork
  for cn in "${CLUSTER_NETWORKS[@]}"; do
    if cidrs_overlap "$subnet" "$cn"; then
      fail "$subnet overlaps clusterNetwork $cn"
    else
      pass "$subnet vs clusterNetwork $cn — clean"
    fi
  done

  # vs serviceNetwork
  for sn in "${SERVICE_NETWORKS[@]}"; do
    if cidrs_overlap "$subnet" "$sn"; then
      fail "$subnet overlaps serviceNetwork $sn"
    else
      pass "$subnet vs serviceNetwork $sn — clean"
    fi
  done

  # vs OVN internal
  if cidrs_overlap "$subnet" "$OVN_INTERNAL"; then
    fail "$subnet overlaps OVN-K internal $OVN_INTERNAL"
  else
    pass "$subnet vs OVN-K internal $OVN_INTERNAL — clean"
  fi

  # vs node IPs
  node_hit=0
  for nip in "${NODE_IPS[@]}"; do
    if ip_in_cidr "$nip" "$subnet"; then
      fail "node IP $nip falls inside $subnet"
      node_hit=1
    fi
  done
  [[ $node_hit -eq 0 ]] && pass "$subnet — no node IPs inside"

  # vs sibling CUDN subnets
  for other in "${CUDN_SUBNETS[@]}"; do
    [[ "$other" == "$subnet" ]] && continue
    if cidrs_overlap "$subnet" "$other"; then
      fail "$subnet overlaps sibling subnet $other"
    else
      pass "$subnet vs sibling $other — clean"
    fi
  done
done

# =============================================================================
# 4. Routes on tenant worker nodes
# =============================================================================
title "4. Existing routes on tenant worker nodes"

for node in "${TENANT_NODES[@]}"; do
  echo ""
  info "Checking routes on $node"
  routes=$(oc debug "node/$node" -- chroot /host ip route show 2>/dev/null | \
    grep -v "^Starting\|^To use\|^Removing\|^Temporary\|^$" || true)

  if [[ -z "$routes" ]]; then
    warn "$node — no route output (debug pod may be slow, rerun if needed)"
    continue
  fi

  hit=0
  for subnet in "${CUDN_SUBNETS[@]}"; do
    parent=$(echo "$subnet" | cut -d. -f1-2)
    match=$(echo "$routes" | grep "^${parent}\." || true)
    if [[ -n "$match" ]]; then
      fail "route conflict on $node for $subnet:"
      echo "$match" | while IFS= read -r r; do echo "         $r"; done
      hit=1
    fi
  done
  [[ $hit -eq 0 ]] && pass "$node — no conflicting routes"
done

# =============================================================================
# 5. Existing CUDN / UDN objects
# =============================================================================
title "5. Existing CUDN / UDN objects in cluster"
echo ""

existing_cudn=$(oc get clusteruserdefinednetwork --no-headers 2>/dev/null || echo "")
if [[ -z "$existing_cudn" ]] || echo "$existing_cudn" | grep -q "No resources"; then
  pass "no existing ClusterUserDefinedNetwork objects"
else
  warn "existing CUDNs found — verify no subnet overlap:"
  echo "$existing_cudn"
fi

existing_udn=$(oc get userdefinednetwork --all-namespaces --no-headers 2>/dev/null || echo "")
if [[ -z "$existing_udn" ]] || echo "$existing_udn" | grep -q "No resources"; then
  pass "no existing UserDefinedNetwork objects"
else
  warn "existing UDNs found — verify no subnet overlap:"
  echo "$existing_udn"
fi

# =============================================================================
# 6. Feature gate
# =============================================================================
title "6. OVN-K feature gate — UserDefinedNetwork"
echo ""

fgstatus=$(oc get featuregate cluster \
  -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo "")

info "featureSet: '${fgstatus}'"

if [[ "$fgstatus" == "TechPreviewNoUpgrade" || \
      "$fgstatus" == "CustomNoUpgrade" ]]; then
  pass "featureSet '$fgstatus' — CUDN enabled"
elif [[ -z "$fgstatus" || "$fgstatus" == "null" ]]; then
  pass "featureSet empty — CUDN is GA on OCP 4.18+ (cluster is OCP 4.20 / k8s v1.33)"
else
  warn "featureSet '$fgstatus' — verify CUDN support on your OCP version"
fi

# =============================================================================
# Summary
# =============================================================================
title "Summary"
echo ""

if [[ $FAILED -eq 0 && $WARNED -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}ALL CHECKS PASSED${RESET} — safe to apply CUDN manifests"
  echo ""
  echo "  Apply order:"
  echo "    oc apply -f cudn/cudn-tenant-a.yaml"
  echo "    oc apply -f cudn/cudn-tenant-b.yaml"
  echo "    oc get clusteruserdefinednetwork -w"
elif [[ $FAILED -eq 0 ]]; then
  echo -e "  ${YELLOW}${BOLD}PASSED WITH WARNINGS ($WARNED warning(s))${RESET} — review before applying"
else
  echo -e "  ${RED}${BOLD}FAILED — $FAILED error(s), $WARNED warning(s)${RESET}"
  echo ""
  echo "  If 10.200.x.x is blocked, try: --subnets 10.201.1.0/24,10.201.2.0/24"
  exit 1
fi
echo ""
