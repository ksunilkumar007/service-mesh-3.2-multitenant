#!/bin/bash
# =============================================================================
# Node Pool — Tenant B
# Labels and taints worker-2 and worker-3 for exclusive tenant-b use.
# Run once before deploying any mesh components.
# =============================================================================

set -e

NODE1="ip-10-0-19-203.ec2.internal"
NODE2="ip-10-0-47-253.ec2.internal"

echo "Labelling tenant-b nodes..."
oc label node ${NODE1} mesh=tenant-b
oc label node ${NODE2} mesh=tenant-b

echo "Tainting tenant-b nodes..."
oc adm taint node ${NODE1} mesh=tenant-b:NoSchedule
oc adm taint node ${NODE2} mesh=tenant-b:NoSchedule

echo "Verifying..."
oc get nodes ${NODE1} ${NODE2} \
  -o custom-columns=\
NAME:.metadata.name,\
MESH-LABEL:.metadata.labels.mesh,\
TAINTS:.spec.taints

echo "Done."
