#!/bin/bash
# =============================================================================
# Patch bookinfo-a deployments with tenant-a nodeSelector + tolerations
# =============================================================================
# WHY:
#   Upstream bookinfo manifest has no nodeSelector. Pods schedule on any
#   available node including infra node which has no ztunnel.
#   This script patches all bookinfo deployments + the gateway deployment
#   to run exclusively on tenant-a nodes.
#
# USAGE:
#   bash bookinfo-patch-a.sh
# =============================================================================

PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"mesh":"tenant-a"},"tolerations":[{"key":"mesh","value":"tenant-a","effect":"NoSchedule"}]}}}}'

echo "Patching bookinfo-a deployments..."
for deploy in details-v1 productpage-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
  oc patch deployment $deploy -n bookinfo-a --type=merge -p "$PATCH"
done

echo "Patching bookinfo-a waypoint deployment..."
oc patch deployment waypoint -n bookinfo-a --type=merge -p "$PATCH"

echo "Patching bookinfo-ingress-a gateway deployment..."
oc patch deployment bookinfo-gateway-a-istio -n bookinfo-ingress-a --type=merge -p "$PATCH"

echo "Done — waiting for rollout..."
oc rollout status deployment -n bookinfo-a --timeout=120s
oc rollout status deployment bookinfo-gateway-a-istio -n bookinfo-ingress-a --timeout=60s
