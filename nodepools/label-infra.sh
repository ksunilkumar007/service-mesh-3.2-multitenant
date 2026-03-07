#!/bin/bash
# =============================================================================
# Node Pool — Infra
# Labels the infra node. No taint — general workloads can schedule here.
# =============================================================================

set -e

NODE="ip-10-0-57-92.ec2.internal"

echo "Labelling infra node..."
oc label node ${NODE} mesh=infra

echo "Verifying..."
oc get node ${NODE} \
  -o custom-columns=\
NAME:.metadata.name,\
MESH-LABEL:.metadata.labels.mesh,\
TAINTS:.spec.taints

echo "Done."
