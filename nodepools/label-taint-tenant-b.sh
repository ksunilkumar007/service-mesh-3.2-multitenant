#!/bin/bash
# =============================================================================
# Node Pool — Tenant B
# Labels and taints worker-2 and worker-3 for exclusive tenant-b use.
# Run once before deploying any mesh components.
# =============================================================================

set -e

NODE1="worker-cluster-89pfx-5"
NODE2="worker-cluster-89pfx-6"

echo "Labelling tenant-b nodes..."
oc label node ${NODE1} mesh=tenant-b --overwrite
oc label node ${NODE2} mesh=tenant-b --overwrite

echo "Tainting tenant-b nodes..."
oc adm taint node ${NODE1} mesh=tenant-b:NoSchedule --overwrite
oc adm taint node ${NODE2} mesh=tenant-b:NoSchedule --overwrite

echo "Verifying..."
oc get nodes ${NODE1} ${NODE2} \
  -o custom-columns=\
NAME:.metadata.name,\
MESH-LABEL:.metadata.labels.mesh,\
TAINTS:.spec.taints

echo "Done."
