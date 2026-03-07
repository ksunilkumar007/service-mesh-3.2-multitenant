#!/bin/bash
# =============================================================================
# Node Pool — Tenant A
# Labels and taints worker-0 and worker-1 for exclusive tenant-a use.
# Run once before deploying any mesh components.
# =============================================================================

set -e

NODE1="ip-10-0-0-5.ec2.internal"
NODE2="ip-10-0-19-190.ec2.internal"

echo "Labelling tenant-a nodes..."
oc label node ${NODE1} mesh=tenant-a
oc label node ${NODE2} mesh=tenant-a

echo "Tainting tenant-a nodes..."
oc adm taint node ${NODE1} mesh=tenant-a:NoSchedule
oc adm taint node ${NODE2} mesh=tenant-a:NoSchedule

echo "Verifying..."
oc get nodes ${NODE1} ${NODE2} \
  -o custom-columns=\
NAME:.metadata.name,\
MESH-LABEL:.metadata.labels.mesh,\
TAINTS:.spec.taints

echo "Done."
