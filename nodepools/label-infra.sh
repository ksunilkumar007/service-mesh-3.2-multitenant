#!/bin/bash
# =============================================================================
# Node Pool — Infra
# Labels infra nodes for general/shared workloads.
# NO mesh=tenant-a label — these nodes are NOT part of any tenant pool.
# NO taint — general workloads (observability, operators) can schedule here.
# =============================================================================
set -e

NODE1="worker-cluster-89pfx-1"
NODE2="worker-cluster-89pfx-2"

echo "Labelling infra nodes..."
oc label node ${NODE1} node-role=infra --overwrite
oc label node ${NODE2} node-role=infra --overwrite

echo "Verifying..."
oc get node ${NODE1} ${NODE2} \
  -o custom-columns=\
NAME:.metadata.name,\
MESH-LABEL:.metadata.labels.mesh,\
ROLE-LABEL:.metadata.labels.node-role,\
TAINTS:.spec.taints

echo "Done."
