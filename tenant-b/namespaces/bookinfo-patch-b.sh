#!/bin/bash
# =============================================================================
# Patch bookinfo-b deployments with tenant-b nodeSelector + tolerations
# =============================================================================
# WHY:
#   Upstream bookinfo manifest has no nodeSelector. Pods schedule on any
#   available node including infra node which has no ztunnel.
#   This script patches all bookinfo deployments + the gateway deployment
#   to run exclusively on tenant-b nodes.
#
# USAGE:
#   bash bookinfo-patch-b.sh
# =============================================================================

PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"mesh":"tenant-b"},"tolerations":[{"key":"mesh","value":"tenant-b","effect":"NoSchedule"}]}}}}'

echo "Patching bookinfo-b deployments..."
for deploy in details-v1 productpage-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
  oc patch deployment $deploy -n bookinfo-b --type=merge -p "$PATCH"
done

echo "Patching bookinfo-b waypoint deployment..."
oc patch deployment waypoint -n bookinfo-b --type=merge -p "$PATCH"

echo "Patching bookinfo-ingress-b gateway deployment..."
oc patch deployment bookinfo-gateway-b-istio -n bookinfo-ingress-b --type=merge -p "$PATCH"

echo "Done — waiting for rollout..."
oc rollout status deployment -n bookinfo-b --timeout=120s
oc rollout status deployment bookinfo-gateway-b-istio -n bookinfo-ingress-b --timeout=60s
