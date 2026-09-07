#!/usr/bin/env bash
set -euo pipefail
: "${DEPLOY_ENV:?Set dev, staging or prod}"
: "${TF_STATE_BUCKET:?Set the bootstrap state bucket}"
: "${TF_STATE_KMS_KEY_ARN:?Set the bootstrap KMS key ARN}"
: "${AWS_REGION:?Set the AWS region}"
case "$DEPLOY_ENV" in dev|staging|prod) ;; *) exit 2 ;; esac
terraform -chdir=infra init -input=false -reconfigure -lockfile=readonly \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=$DEPLOY_ENV/terraform.tfstate" \
  -backend-config="workspace_key_prefix=$DEPLOY_ENV/workspaces" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="kms_key_id=$TF_STATE_KMS_KEY_ARN" \
  -backend-config="use_lockfile=true"
