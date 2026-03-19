#!/bin/bash
# =============================================================================
# Node Pool — Tenant A
# Labels and taints worker-0 and worker-1 for exclusive tenant-a use.
# Run once before deploying any mesh components.
# =============================================================================

set -e

NODE1="worker-cluster-89pfx-3"
NODE2="worker-cluster-89pfx-4"

echo "Labelling tenant-a nodes..."
oc label node ${NODE1} mesh=tenant-a --overwrite
oc label node ${NODE2} mesh=tenant-a --overwrite

echo "Tainting tenant-a nodes..."
oc adm taint node ${NODE1} mesh=tenant-a:NoSchedule --overwrite
oc adm taint node ${NODE2} mesh=tenant-a:NoSchedule --overwrite

echo "Verifying..."
oc get nodes ${NODE1} ${NODE2} \
  -o custom-columns=\
NAME:.metadata.name,\
MESH-LABEL:.metadata.labels.mesh,\
TAINTS:.spec.taints

echo "Done."
