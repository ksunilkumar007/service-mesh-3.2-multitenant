#!/bin/bash
# =============================================================================
# create-tempo-s3-secret.sh — Create AWS S3 bucket and Tempo secret
# =============================================================================
# PURPOSE:
#   Creates an S3 bucket for Tempo trace storage and the corresponding
#   Kubernetes secret in the tracing namespace.
#
# PREREQUISITES:
#   - aws CLI installed on bastion
#   - aws-creds secret in kube-system (created by OCP installer on AWS)
#   - tracing namespace must exist before running this script
#
# WHY NOT YAML:
#   The bucket name includes the cluster infrastructure name (dynamic).
#   The secret values come from aws-creds (dynamic).
#   A script handles this cleanly — a static yaml cannot.
#
# IDEMPOTENT:
#   Safe to run multiple times — skips bucket creation if already exists.
# =============================================================================
set -e

REGION="us-east-1"
NAMESPACE="tracing"

echo "Reading AWS credentials from kube-system/aws-creds..."
AWS_ACCESS_KEY=$(oc get secret aws-creds -n kube-system \
  -o jsonpath='{.data.aws_access_key_id}' | base64 -d)
AWS_SECRET_KEY=$(oc get secret aws-creds -n kube-system \
  -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)

INFRA_NAME=$(oc get infrastructure cluster \
  -o jsonpath='{.status.infrastructureName}')
BUCKET_NAME="tempo-traces-${INFRA_NAME}"

echo "Bucket name: $BUCKET_NAME"

# Create bucket if it doesn't exist
if AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY \
   AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY \
   aws s3 ls s3://$BUCKET_NAME --region $REGION 2>/dev/null; then
  echo "Bucket already exists, skipping creation"
else
  echo "Creating S3 bucket..."
  AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY \
  AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY \
  aws s3 mb s3://$BUCKET_NAME --region $REGION
fi

# Create or update the secret
echo "Creating tempo-s3-secret in namespace $NAMESPACE..."
oc create secret generic tempo-s3-secret -n $NAMESPACE \
  --from-literal=bucket="${BUCKET_NAME}" \
  --from-literal=endpoint="https://s3.amazonaws.com" \
  --from-literal=access_key_id="${AWS_ACCESS_KEY}" \
  --from-literal=access_key_secret="${AWS_SECRET_KEY}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Done. Secret tempo-s3-secret created in $NAMESPACE"
echo "Bucket: $BUCKET_NAME"
