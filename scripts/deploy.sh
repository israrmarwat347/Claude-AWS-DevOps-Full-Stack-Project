#!/usr/bin/env bash
set -euo pipefail
bash scripts/tf-init.sh
cluster="$TF_VAR_project-$DEPLOY_ENV"
service="$cluster"
previous_task=""
previous_index_version=""
bucket=""
distribution=""
frontend_changed=false
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

# Treat AccessDenied as a real error; a service missing during the first deploy is expected.
if aws ecs describe-services --cluster "$cluster" --services "$service" --output json > "$scratch_dir/previous.json" 2> "$scratch_dir/describe.err"; then
  previous_task=$(jq -r '.services[0].deployments[]? | select(.rolloutState == "COMPLETED") | .taskDefinition' "$scratch_dir/previous.json")
else
  if ! grep -q 'ClusterNotFoundException' "$scratch_dir/describe.err"; then cat "$scratch_dir/describe.err" >&2; exit 1; fi
fi

rollback() {
  status=$?
  trap - ERR
  set +e
  echo 'Deployment failed. Restoring the previous application release where available.' >&2
  if [ -n "$previous_task" ]; then
    aws ecs update-service --cluster "$cluster" --service "$service" --task-definition "$previous_task" --force-new-deployment >/dev/null
    aws ecs wait services-stable --cluster "$cluster" --services "$service"
    live=$(aws ecs describe-services --cluster "$cluster" --services "$service" --query 'services[0].taskDefinition' --output text)
    if [ "$live" != "$previous_task" ]; then echo 'ROLLBACK FAILED: inspect ECS deployments immediately.' >&2; fi
  else
    echo 'No previously healthy ECS release exists. Repair the first deployment and rerun.' >&2
  fi
  if [ "$frontend_changed" = true ]; then
    if [ -n "$previous_index_version" ] && [ "$previous_index_version" != None ]; then
      aws s3api get-object --bucket "$bucket" --key index.html --version-id "$previous_index_version" "$scratch_dir/old-index.html" >/dev/null
      aws s3 cp "$scratch_dir/old-index.html" "s3://$bucket/index.html" --content-type text/html --cache-control no-cache >/dev/null
    else
      aws s3 rm "s3://$bucket/index.html" >/dev/null
    fi
    invalidation=$(aws cloudfront create-invalidation --distribution-id "$distribution" --paths / /index.html --query Invalidation.Id --output text)
    aws cloudfront wait invalidation-completed --distribution-id "$distribution" --id "$invalidation"
  fi
  echo 'Infrastructure and database changes are not automatically undone. Revert the Git change and review a fresh Terraform plan.' >&2
  exit "$status"
}
trap rollback ERR

terraform -chdir=infra plan -input=false -lock-timeout=5m -var-file="environments/$DEPLOY_ENV.tfvars" -out="$scratch_dir/release.tfplan"
terraform -chdir=infra apply -input=false -auto-approve "$scratch_dir/release.tfplan"
expected=$(terraform -chdir=infra output -raw task_definition_arn)
aws ecs wait services-stable --cluster "$cluster" --services "$service"
aws ecs describe-services --cluster "$cluster" --services "$service" --output json > "$scratch_dir/service.json"
jq -e --arg expected "$expected" '.services[0] | .taskDefinition == $expected and .runningCount >= .desiredCount and (.deployments | length == 1) and .deployments[0].rolloutState == "COMPLETED"' "$scratch_dir/service.json" >/dev/null
site=$(terraform -chdir=infra output -raw site_url)
# Check the running commit; a circuit-breaker rollback can be stable but still serve old code.
curl --fail --silent --show-error --retry 6 --retry-delay 5 --retry-all-errors --max-time 20 "$site/api/health/live" > "$scratch_dir/health.json"
jq -e --arg sha "$TF_VAR_release_sha" '.status == "ok" and .release == $sha' "$scratch_dir/health.json" >/dev/null
curl --fail --silent --show-error --max-time 20 "$site/api/config" | jq -e '.localAuth == false and .mockClaude == false and (.clientId | length > 0)' >/dev/null

bucket=$(terraform -chdir=infra output -raw frontend_bucket)
distribution=$(terraform -chdir=infra output -raw distribution_id)
# Listing works for a new empty bucket and avoids confusing a missing object with AccessDenied.
previous_index_version=$(aws s3api list-object-versions --bucket "$bucket" --prefix index.html --query 'Versions[?Key==`index.html` && IsLatest==`true`].VersionId | [0]' --output text)
test -f frontend/dist/index.html
# Upload hashed assets first, then switch the entry point. Never delete old assets on deployment.
aws s3 sync frontend/dist/ "s3://$bucket/" --exclude index.html --cache-control 'public,max-age=31536000,immutable' >/dev/null
frontend_changed=true
aws s3 cp frontend/dist/index.html "s3://$bucket/index.html" --content-type text/html --cache-control no-cache >/dev/null
invalidation=$(aws cloudfront create-invalidation --distribution-id "$distribution" --paths / /index.html --query Invalidation.Id --output text)
aws cloudfront wait invalidation-completed --distribution-id "$distribution" --id "$invalidation"
curl --fail --silent --show-error --max-time 20 "$site/" -o "$scratch_dir/index.html"
cmp frontend/dist/index.html "$scratch_dir/index.html"
trap - ERR
echo "Deployment verified: $site"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "Deployed **$DEPLOY_ENV**: $site (commit $TF_VAR_release_sha)" >> "$GITHUB_STEP_SUMMARY"; fi
