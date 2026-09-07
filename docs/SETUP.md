# Setup guide

Commands assume Bash (Linux, macOS, or WSL on Windows). Run them from the repository root unless another directory is shown. Keep the terminal's AWS SSO session active. Do not paste API keys into chat, Terraform variables, GitHub variables, or command-line arguments.

## 1. Prerequisites and your values

Install Git, GitHub CLI, AWS CLI v2, Terraform 1.16.1, Python 3.12, uv 0.11.33, Node.js 24, Docker, curl, and jq. Docker is required for local container builds; GitHub runners provide it for CI. You also need an Anthropic account with API access and available credit, and an existing domain delegated to a Route 53 public hosted zone in your AWS account.

```bash
# TODO: Replace all values marked below. Do not set AWS access keys.
export AWS_PROFILE=claude-platform-admin        # TODO: Your AWS SSO profile
export AWS_REGION=eu-west-1                    # TODO: Change consistently if needed
export PROJECT_NAME=claude-platform
export GITHUB_REPO=OWNER/REPOSITORY             # TODO: Existing GitHub repository
export REPO_URL=https://github.com/OWNER/REPOSITORY.git  # TODO: Your repo URL
export DOMAIN_NAME=example.com                 # TODO: Your real domain
export ROUTE53_ZONE_ID=Z_REPLACE_ME             # TODO: Public hosted zone ID

aws configure sso --profile "$AWS_PROFILE"
aws sso login --profile "$AWS_PROFILE"
aws sts get-caller-identity
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws route53 get-hosted-zone --id "$ROUTE53_ZONE_ID"
gh auth login
```

The bootstrap operator needs permission to provision the listed resources, roles, policies and an OIDC provider. Use a dedicated AWS sandbox account when learning. Runtime tasks use narrowly scoped roles; the bootstrap/deployment operator is an infrastructure administrator for this project.

If your domain is hosted elsewhere, first delegate its public hosted zone to Route 53 or adapt the certificate validation records. `example.com` is a placeholder and will not deploy successfully. The user-facing site uses its default CloudFront domain; `dev-api`, `staging-api`, and `prod-api` under your real domain are secured ALB origin names.

## 2. Publish the repository

For an **empty** existing GitHub repository, from this extracted project directory:

```bash
git init -b main
git add .
git diff --cached --check
git status --short
# TODO: Configure your Git author locally if git commit requests it.
git commit -m "feat: add Claude AWS DevOps platform"
git remote add origin "$REPO_URL"
git push -u origin main
git switch -c dev
git push -u origin dev
```

If a remote already exists, inspect `git remote -v`; use it if correct, otherwise intentionally run `git remote set-url origin "$REPO_URL"`. If your target repository has existing commits, clone it into a separate directory, create a feature branch, copy this project's files into that checkout, and open a PR. Do not force-push over existing work. Initial workflow runs can fail until AWS/GitHub configuration is complete; rerun Release after setup.

## 3. Provision bootstrap resources

```bash
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_project="$PROJECT_NAME"
export TF_VAR_github_repository="$GITHUB_REPO"
export TF_VAR_route53_zone_id="$ROUTE53_ZONE_ID"
# TODO: If a GitHub OIDC provider already exists in this account, set its ARN:
# export TF_VAR_existing_oidc_provider_arn="arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"

terraform -chdir=infra/bootstrap init -input=false
terraform -chdir=infra/bootstrap plan -out=bootstrap.tfplan
terraform -chdir=infra/bootstrap apply bootstrap.tfplan
terraform -chdir=infra/bootstrap output -json > bootstrap-outputs.json
export TF_STATE_BUCKET=$(jq -r .state_bucket.value bootstrap-outputs.json)
export TF_STATE_KMS_KEY_ARN=$(jq -r .state_kms_key_arn.value bootstrap-outputs.json)
export RUNTIME_BOUNDARY_ARN=$(jq -r .runtime_boundary_arn.value bootstrap-outputs.json)
```

Review the plan before applying. Bootstrap creates ECR repositories, empty Anthropic secret containers, SNS topics, a protected encrypted state bucket, a KMS key, and the GitHub OIDC provider/roles. It never provisions a secret value. Keep `bootstrap-outputs.json` local; it is ignored by Git.

Migrate bootstrap state from your machine to the newly created bucket:

```bash
cat > infra/bootstrap/backend.remote.tf <<'EOF'
terraform {
  backend "s3" {}
}
EOF
terraform -chdir=infra/bootstrap init -migrate-state \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=bootstrap/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="kms_key_id=$TF_STATE_KMS_KEY_ARN" \
  -backend-config="use_lockfile=true"
```

Answer Terraform's state migration question after verifying the destination. `backend.remote.tf` contains no credentials and is a local operator file excluded from Git. Retain a secure backup of local bootstrap state until successful migration. OIDC deployment roles cannot read or modify the bootstrap state prefix.

## 4. Load Anthropic keys without exposing them

```bash
cd backend
uv sync --frozen --python 3.12
cd ..
for environment in dev staging prod; do
  secret_arn=$(jq -r --arg e "$environment" '.anthropic_secret_arns.value[$e]' bootstrap-outputs.json)
  uv run --project backend python scripts/set-secret.py --region "$AWS_REGION" --secret-id "$secret_arn"
done
```

Each call prompts for a hidden key. Prefer separate Anthropic workspace keys/spend limits for environments. Do not store Anthropic keys in GitHub Actions; running ECS tasks retrieve them using their task role. Rotated keys refresh within five minutes.

## 5. Configure GitHub OIDC and variables

```bash
gh variable set AWS_ACCOUNT_ID --repo "$GITHUB_REPO" --body "$AWS_ACCOUNT_ID"
gh variable set AWS_REGION --repo "$GITHUB_REPO" --body "$AWS_REGION"
gh variable set PROJECT_NAME --repo "$GITHUB_REPO" --body "$PROJECT_NAME"
gh variable set DOMAIN_NAME --repo "$GITHUB_REPO" --body "$DOMAIN_NAME"
gh variable set ROUTE53_ZONE_ID --repo "$GITHUB_REPO" --body "$ROUTE53_ZONE_ID"
gh variable set TF_STATE_BUCKET --repo "$GITHUB_REPO" --body "$TF_STATE_BUCKET"
gh variable set TF_STATE_KMS_KEY_ARN --repo "$GITHUB_REPO" --body "$TF_STATE_KMS_KEY_ARN"
gh variable set RUNTIME_BOUNDARY_ARN --repo "$GITHUB_REPO" --body "$RUNTIME_BOUNDARY_ARN"
gh variable set BUILD_ROLE_ARN --repo "$GITHUB_REPO" --body "$(jq -r .build_role_arn.value bootstrap-outputs.json)"

for environment in dev staging prod; do
  gh api --method PUT "repos/$GITHUB_REPO/environments/$environment"
  topic=$(jq -r --arg e "$environment" '.notification_topic_arns.value[$e]' bootstrap-outputs.json)
  gh variable set NOTIFICATION_TOPIC_ARN --repo "$GITHUB_REPO" --env "$environment" --body "$topic"
done
```

In GitHub → repository **Settings → Environments**, configure **deployment branch rules before running Release**:

| Environment | Allowed deployment branch | Review policy |
| --- | --- | --- |
| dev | `dev` | Optional |
| staging | `main` | Optional |
| prod | `main` | Required reviewer; prevent self-review where available |

Availability of environment protection features depends on your GitHub plan and repository visibility. If required reviewers are unavailable, keep production releases disabled until you have an equivalent reviewed release process. Set repository Actions permissions to read-only by default.

**No GitHub secrets containing AWS access keys or Anthropic keys are required.** Build OIDC trust accepts only the exact repo's main/dev branch subjects. Deploy trust accepts only the exact repo's corresponding environment subject. Environment branch rules are essential because an environment OIDC subject does not contain the branch name. PR plans use separate read-only roles and run only for same-repository PRs.

## 6. Set up email notifications

```bash
read -r -p 'Notification email address: ' NOTIFICATION_EMAIL  # TODO: Your email
for environment in dev staging prod; do
  topic=$(jq -r --arg e "$environment" '.notification_topic_arns.value[$e]' bootstrap-outputs.json)
  aws sns subscribe --topic-arn "$topic" --protocol email --notification-endpoint "$NOTIFICATION_EMAIL"
done
```

Confirm each SNS subscription using the emails AWS sends. The generated workflows publish success/failure messages to these topics when run. No subscription or email has been sent during project generation.

## 7. Protect branches and deploy

In Settings → Rules → Rulesets (or Branches), protect `main`: require pull requests, one reviewer, passing `validate` CI, resolved discussions, and current branches. Block force pushes and deletions. Review `docs/SECURITY.md` for CODEOWNERS guidance. The first successful CI run makes its check name selectable.

```bash
# TODO: Commit your intentional nonsecret configuration edits before releasing.
git switch dev
git push origin dev
# If no commit changed since initial setup, explicitly rerun the workflow:
gh workflow run release.yml --repo "$GITHUB_REPO" --ref dev
gh run list --repo "$GITHUB_REPO" --workflow release.yml --limit 5
```

Follow the latest run in GitHub Actions. Certificate DNS validation and the first CloudFront/ECS deployment can take time. Review your AWS quotas, especially VPC count, NAT/EIP limits, Fargate vCPU, and CloudFront's weighted security-group prefix list.

When dev is healthy, open and merge a reviewed PR from dev to main:

```bash
gh pr create --repo "$GITHUB_REPO" --base main --head dev \
  --title "Release Claude platform" \
  --body "Release the tested Claude platform. Review CI and Terraform plans before merging."
```

Merge through the protected GitHub PR UI. The workflow builds once, deploys staging, then awaits the configured production approval. Both environments use the identical backend image digest and frontend build from that workflow run.

## 8. Read outputs and create the first user

```bash
export DEPLOY_ENV=dev                          # TODO: Select environment
export TF_VAR_domain_name="$DOMAIN_NAME"
export TF_VAR_runtime_boundary_arn="$RUNTIME_BOUNDARY_ARN"
bash scripts/tf-init.sh
terraform -chdir=infra output
export USER_POOL_ID=$(terraform -chdir=infra output -raw user_pool_id)
uv run --project backend python scripts/create-user.py --region "$AWS_REGION" --pool-id "$USER_POOL_ID"

```

The script prompts for your email and a hidden temporary password and creates the user with invitation delivery suppressed. No password appears in the shell history or process arguments. Sign in at the `site_url` output, change the temporary password, and optionally enroll TOTP MFA. Use the console to require MFA for a stronger organization policy and adapt Terraform consistently.

Verify a real prompt streams, reopen the conversation to check persistence, and sign in as a second user to confirm histories differ. These are live integration acceptance checks; local tests cannot replace them.

## 9. Manual deployment equivalent

Use this for diagnosis after bootstrap. It still plans and applies AWS changes.

```bash
export DEPLOY_ENV=dev                          # TODO: Target environment
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_project="$PROJECT_NAME"
export TF_VAR_domain_name="$DOMAIN_NAME"
export TF_VAR_route53_zone_id="$ROUTE53_ZONE_ID"
export TF_VAR_runtime_boundary_arn="$RUNTIME_BOUNDARY_ARN"
export TF_VAR_release_sha=$(git rev-parse HEAD)
export ECR_REPOSITORY="$PROJECT_NAME-$DEPLOY_ENV"
export ECR_REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
export IMAGE_TAG="$TF_VAR_release_sha-manual-$(date -u +%Y%m%d%H%M%S)"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
docker build --platform linux/amd64 --pull -f backend/Dockerfile -t "$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" .
docker push "$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"
export IMAGE_DIGEST=$(aws ecr describe-images --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)
export TF_VAR_image_uri="$ECR_REGISTRY/$ECR_REPOSITORY@$IMAGE_DIGEST"
(cd frontend && npm ci && npm run build)
bash scripts/deploy.sh
```

Before manual release, run the same tests/audits/image scan as CI. On Apple Silicon the `--platform linux/amd64` flag is required because Terraform defines x86_64 tasks.

## Setup Checklist

1. Install prerequisites and run the local mock chat.
2. Supply GitHub repo URL, AWS SSO profile/region, real domain, and Route 53 hosted zone ID.
3. Publish to an empty repository, or use a feature branch in an existing repository without overwriting its history.
4. Review/apply bootstrap and migrate bootstrap state to encrypted S3.
5. Enter Anthropic keys through the hidden-input script for each environment.
6. Configure GitHub variables and dev/staging/prod environments with branch restrictions and production reviewers.
7. Subscribe your email to SNS and confirm the subscriptions.
8. Enable main branch protection and required CI checks.
9. Run Release on dev; inspect its Terraform plan, deployment result and monitoring.
10. Create a Cognito test user and verify sign-in, a real streamed response, persistence and tenant isolation.
11. Open/review/merge dev → main; verify staging, then approve production.
12. Set AWS/Anthropic spending alerts, test rollback and restore, and complete the production readiness checks in OPERATIONS.md.
