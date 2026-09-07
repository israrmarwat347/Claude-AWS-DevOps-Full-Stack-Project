# Validation record

Checked September 7, 2026, during generation. Tests used local mocks, generated test signing keys and simulated AWS services. No paid Anthropic request or live AWS deployment was made.

| Check | Result |
| --- | --- |
| Backend unit/integration tests | 35 passed: tenant isolation, DynamoDB/memory parity, leases, retries, rate limits, pagination, TTL visibility, SSE/JSON errors, timeout handling, body limits, Cognito JWT verification, actual SDK `/v1/messages` serialization/retry/stream parsing, and Secrets Manager cache refresh |
| Frontend tests | 3 passed: split UTF-8/SSE framing, interrupted streams, and post-200 error events |
| React TypeScript + Vite production build | Passed |
| Python lint and formatting | Passed |
| Python dependency audit | No known vulnerabilities reported for the locked runtime requirements |
| npm dependency audit | Zero vulnerabilities reported |
| GitHub workflow syntax | actionlint passed for all four workflows |
| Shell syntax | Deployment, Terraform init and container entrypoint passed `bash -n` |
| Terraform formatting/syntax | `terraform fmt -recursive` passed |
| Terraform dependency initialization | AWS 6.63.0 and Random 3.9.0 downloaded and signed checksums recorded in provider locks |
| Terraform schema validation | **Not completed:** this runtime could not start provider plugins; Terraform reported a provider handshake/startup failure |
| Trivy infrastructure/secrets scan | Complete JSON report: zero unaccepted HIGH/CRITICAL findings and zero detected secrets; four architecture rule exceptions documented in SECURITY.md |
| Container configuration scan | 20 checks passed in Trivy's configuration report |
| Git whitespace and ignores | Passed; `.env`, Terraform states/backups, secret JSON, private keys, node_modules and Python caches are ignored |
| Docker image build/image vulnerability scan | **Not run locally:** Docker is unavailable in this runtime; mandatory build/scan steps are included in GitHub Actions |
| Live AWS plan/apply, OIDC, DNS/TLS, Cognito and Claude integration | **Not run:** requires your account, domain, credentials and configuration |
| GitHub push | **Not run:** repository URL was not supplied |

The complete Trivy report was inspected even though the execution wrapper did not return a final process status. It records 20 successful Docker configuration checks, 44 successful application Terraform checks and 29 successful bootstrap checks, with zero unaccepted failures. The generated CI reruns these checks against the actual commit. The scan uses the HIGH/CRITICAL threshold; accepted findings are not the same as a claim that all hardening recommendations have been implemented.

Python emitted one upstream Starlette/AnyIO deprecation warning during tests; all tests passed. The dependency locks and audits reflect the versions available at generation time and must be refreshed as vulnerabilities and packages change.

This is a complete implementation with local verification, **not a claim of a certified, load-tested or live-validated production system**. A successful live Terraform plan/apply, IAM review, real sign-in/chat acceptance test, load test, rollback drill and restore drill remain required before production traffic. Follow OPERATIONS.md.
