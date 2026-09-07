# Security model

## Credentials and authorization

The repository contains no API keys or AWS credentials. `.gitignore` excludes `.env`, local secret files, private keys, Terraform state, saved plans, dependency directories and caches. Both provider lockfiles, `uv.lock`, `requirements.txt`, and `package-lock.json` are intentionally committed. `.dockerignore` separately excludes secret/state files from the build context.

Bootstrap creates Secrets Manager containers with no `secret_version` resource. API keys never enter Terraform variables or state. `scripts/set-secret.py` takes hidden keyboard input and sends the value directly through boto3. Tasks cache it for up to five minutes. Use separate Anthropic workspace keys and limits for production.

GitHub Actions obtains short-lived credentials through OIDC. Trust policies restrict the audience and exact repository subjects. Build, PR-plan, and environment-deploy roles are separate. Production environment branch restrictions and reviewers must be configured before enabling release. Fork PRs never receive AWS credentials; the project does not use `pull_request_target`.

The ECS execution role can pull only its environment's ECR image and write its log streams. The task role can read only its Anthropic secret and operate on only its DynamoDB table. Runtime IAM roles have a bootstrap-owned permissions boundary; deployment roles cannot remove or edit it, create roles outside the runtime namespace, or edit their own trust/policies.

Infrastructure deployment is privileged. Resource names scope S3, DynamoDB, runtime IAM, log groups, ECS services, ALB, and other supported APIs. Creation and discovery actions for some services require wildcard resources. Some control-plane permissions are shared across environments in the single-account default. This is not strict production isolation; deploy separate accounts and organization SCPs when a hard boundary is required. IAM Access Analyzer and a live least-privilege review are required before enterprise use.

Read-only PR roles can read their environment's Terraform state, including the random CloudFront origin header. Only grant write access to trusted repository collaborators; do not treat same-repo PR code as untrusted public code. Plans stay in the runner and logs; no binary plan artifact is published. Private repositories are appropriate for infrastructure whose state-derived metadata should not be public.

## Network, encryption and browser protections

- CloudFront uses its default trusted HTTPS certificate. Origin traffic uses a DNS-validated ACM certificate for the regional ALB. All ALB listeners are HTTPS.
- ALB ingress accepts only CloudFront's origin-facing managed prefix list. A random 48-character header is required to reach targets. The value is sensitive Terraform state data protected by S3/KMS.
- ALB-to-task traffic is encrypted on 8443 using a per-task generated certificate. ALB does not verify target certificates; security groups constrain the hop. A service mesh/private PKI would be needed for authenticated task-to-task TLS.
- ECS tasks have no public IP. HTTPS egress goes through NAT. A DynamoDB gateway endpoint restricts traffic to the environment table.
- S3 uses encryption at rest, public access blocking, versioning, and TLS-only policies. CloudFront alone can read frontend objects. The state bucket uses a rotating customer-managed KMS key and state locks.
- DynamoDB has at-rest encryption, PITR and TTL. Secrets Manager and CloudWatch provide service encryption at rest. Notification topics use a KMS key that permits CloudWatch alarms and authorized publishers.
- The container is nonroot, drops Linux capabilities, uses a read-only root filesystem and an ephemeral writable `/tmp`. The TLS key is generated there and never baked into the image.
- A restrictive CSP, nosniff, HSTS, referrer policy and frame denial are sent by CloudFront. React renders message text, not raw HTML. No external font or analytics service is loaded.
- Access tokens live in memory, not localStorage. PKCE transaction state uses sessionStorage. Cognito access JWTs are verified for signature, issuer, client, expiry, scope and token use.

## Abuse, retention and logging

Only an administrator can create Cognito users. API/chat counters are shared in DynamoDB and apply across replicas. The ALB WAF adds IP rate limiting in staging/prod. A CloudFront viewer-request function overwrites client-supplied `X-Forwarded-For` so the WAF's first forwarded address is the real viewer address. This is a basic rate rule, not a complete bot-management or prompt-safety system.

Application logs record generated request IDs, response-header latency, error classes and token usage. They omit prompts, answers and authorization headers. ALB access logs contain paths and request metadata: they must be protected and retained according to your policy. The API has no model tools, arbitrary URL fetches or shell execution, which limits prompt-injection impact to text output.

Expiration hides conversations immediately in application reads; DynamoDB TTL deletion is asynchronous. PITR/backups may retain older data for the configured recovery period. Account erasure and regulated retention requirements need a separate verified procedure, including backup expiration. Deleting a conversation does not instantly remove every historical backup.

## Scanner decisions

The Trivy configuration includes four path-scoped, documented accepted findings:

| Rule | Rationale |
| --- | --- |
| AWS-0011 | WAF sits on the ALB for paid API requests in staging/prod; public static assets do not use a global CloudFront WAF. |
| AWS-0053 | ALB is intentionally public but restricted by CloudFront IPs, HTTPS and the origin secret. |
| AWS-0132 | S3 static files and ALB logs use SSE-S3; ALB log delivery requires SSE-S3. State uses a customer-managed key. |
| AWS-0104 | Outbound 443 is necessary for changing public Anthropic/AWS endpoints. Add an egress proxy to enforce DNS-level allowlists. |

No leaked-secret or dependency-vulnerability finding is ignored. Image scans block fixable HIGH/CRITICAL vulnerabilities; findings without a fix require separate operational review. The architecture is reviewed at the scanner's HIGH/CRITICAL threshold; lower-severity hardening remains an operator decision.

## Repository protection

Use this optional `.github/CODEOWNERS` pattern after replacing the owner. GitHub must recognize the account/team and it must have write access:

```text
# TODO: Replace @YOUR-REVIEWER with a real GitHub account or team.
/.github/ @YOUR-REVIEWER
/infra/ @YOUR-REVIEWER
/backend/app/auth.py @YOUR-REVIEWER
/scripts/deploy.sh @YOUR-REVIEWER
```

Require code-owner review for these paths, passing CI, and at least one main PR approval. Restrict who can edit workflow files and environment variables. Review the workflow action SHA updates, container image changes, and dependency lock changes.

To report a vulnerability, use your repository's GitHub private vulnerability reporting feature after enabling it. Do not post credentials, customer text, or exploitable details in a public issue.
