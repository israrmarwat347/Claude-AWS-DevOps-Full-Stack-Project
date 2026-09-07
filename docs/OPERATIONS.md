# Operations and recovery

## What a successful deployment means

`scripts/deploy.sh` reviews infrastructure through a saved plan and applies that exact plan in the same trusted workflow job. It waits for ECS stability, requires the expected task definition with one completed deployment, checks the live Git release SHA, verifies that mock/local authentication are disabled, publishes the static assets, switches `index.html`, invalidates CloudFront and compares the served entrypoint with the build.

The smoke check is deliberately free of paid Claude calls and user passwords. Complete the manual live acceptance test in SETUP.md before promoting real traffic. CI checks and a healthy HTTP endpoint alone do not prove Cognito sign-in, Anthropic account credit/model access, NAT connectivity or IAM permissions work in a new AWS account.

## Rollback

ECS has the deployment circuit breaker enabled with rollback. The shell deployment script additionally captures the previous completed task definition and S3 index version. On deployment/smoke failure it restores the prior task, waits for stability, and restores the prior frontend index if it changed. Old hashed assets remain in S3, so the previous index remains usable. First deployments have no prior healthy release to restore.

Rollback is for the application, not arbitrary infrastructure or database changes. Network changes, deleted resources, and incompatible data migrations cannot be made safe by restoring a container. Use additive infrastructure changes and backward-compatible storage/API evolution. Large/destructive infrastructure changes require a dedicated reviewed maintenance plan.

An emergency ECS rollback changes live state outside Terraform. The next plan will detect that difference. Revert the bad Git change, review a new plan, and deploy the corrected release; do not repeatedly reapply the bad commit. A stable service can still be the old release, which is why the workflow verifies both task definition and `/api/health/live` release SHA.

If the runner is forcibly cancelled or loses credentials, its rollback trap may not run. ECS's circuit breaker still covers service deployment failures. Inspect both ECS and S3/CloudFront before the next release.

Manual emergency rollback (use the last verified task definition):

```bash
# TODO: Set your real environment and known-good task definition.
export CLUSTER_NAME=claude-platform-prod
export GOOD_TASK=arn:aws:ecs:eu-west-1:123456789012:task-definition/claude-platform-prod:42
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$CLUSTER_NAME" --task-definition "$GOOD_TASK"
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$CLUSTER_NAME"
```

Then verify sign-in, chat and history, and reconcile the release in Git/Terraform. Do not delete previous ECR digests or old S3 hashed assets until their rollback window has closed.

## Monitoring

| Signal | Where to look | Likely next action |
| --- | --- | --- |
| No healthy ALB targets | ECS stopped task reasons and `/ecs/<project>-<env>` logs | Check image pull, task volume permissions, Secrets Manager value and task IAM. |
| HTTP 502/504 | ALB logs and application error class | Check upstream health/credit, NAT, DNS and timeout settings. |
| Stream `error` after HTTP 200 | `chat_error` log metric and stream-error alarm | Inspect the request ID and upstream error class; retry with the same request ID. |
| HTTP 401 | Cognito client/pool/issuer and token expiry | Use an access token from the configured client; sign in again. |
| HTTP 409 | Active conversation lease | Wait for the active generation; a killed task's lease expires after 240 seconds. |
| HTTP 429 | Per-user minute limit or upstream rate limit | Honor Retry-After and inspect Anthropic limits. |
| HTTP 413 | Request/history budget | Shorten the message or start a new conversation. |
| CloudFront 502 before API | ACM DNS/certificate, origin domain, listener | Confirm trusted TLS certificate and DNS validation; inspect origin headers/SG rules. |
| Terraform AccessDenied | Exact denied IAM action/resource in logs | Compare with bootstrap policy; make a minimal reviewed permission change. Never attach AdministratorAccess to fix CI. |

CloudWatch includes ECS CPU/memory and HTTP/stream error widgets, plus unhealthy-target/error alarms. ALB request counts, token usage logs and Fargate task count should guide load testing. CPU scaling alone may underrepresent I/O-bound chat concurrency; adjust scaling signals/capacity based on your workload before high traffic.

Optional TOTP is configured in Cognito. Make MFA mandatory if your organization's access policy requires it. Existing access JWTs can remain valid until their 15-minute expiry even after a sign-out or user disable; instant revocation would require a server-side session/denylist strategy.

## Restore and retention

1. Stop writes or plan a controlled cutover before restoring history.
2. Use DynamoDB point-in-time recovery to a **new table**, keeping the original intact.
3. Validate sample user partitions, counts and conversation contents with an authorized operator.
4. Review the runtime IAM/table configuration and Terraform import/migration needed to use the restored table.
5. Deploy the corrected table binding and verify reads/writes for test users. Do not delete the original until acceptance and retention requirements are met.

Test a restore in staging and record measured recovery time. This repository does not claim a tested RTO/RPO. S3 versioning protects entrypoints/state; it does not substitute for reviewing state migrations. Never restore Terraform state merely to hide real cloud resource changes.

## Cost controls

This Fargate design incurs ongoing charges even without users: ALBs, NAT gateways, public IPv4 addresses and task runtime are the main fixed components. Staging and prod multiply these costs. WAF, CloudWatch, KMS, storage, data transfer and Anthropic tokens add variable charges.

Start with dev only. Set AWS Budgets alerts and Anthropic workspace spending limits before broad access. Budgets are alerts, not a universal automatic shutoff. Use the [AWS Pricing Calculator](https://calculator.aws/) with your region, AZ count, tasks, NAT traffic and expected usage; no unverified monthly dollar estimate is promised here.

The application caps output tokens, input length, history and per-user request rates. These controls limit some exposure but are not a strict global monetary budget. An organization-wide budget/quota service would be required for a hard application spend ceiling.

## Teardown

Review a `terraform plan -destroy` for one environment using its state and variables. Production has explicit deletion protections. Change those through a reviewed commit only when data removal is intended, retain backups, and separately empty versioned buckets if deletion is required. Buckets have `force_destroy=false`; bootstrap state/KMS have `prevent_destroy=true`. Secrets have a 30-day recovery window.

Do not run blanket account cleanup or delete the bootstrap bucket while application states are in use. No destroy has been executed during generation.

## Production acceptance

- Complete a live dev → staging → production release with real AWS identity, DNS and Claude calls.
- Verify account-specific IAM permissions, service quotas, email confirmations, Cognito sign-in/MFA and tenant isolation.
- Perform concurrency/load tests and observe latency, request rates, task memory/CPU and token usage.
- Exercise a failed release, cancellation and rollback; test a DynamoDB restore.
- Configure cost alerts, responders, data retention and account-level security logging.
- Confirm protected environments/branches and review all documented scanner decisions.
