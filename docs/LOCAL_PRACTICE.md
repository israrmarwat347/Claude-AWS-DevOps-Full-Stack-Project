# Free local practice

This mode is designed for learning and testing the application without a cloud bill.

It uses:

- simulated Claude responses (`MOCK_CLAUDE=true`)
- local demo authentication (`LOCAL_AUTH=true`)
- an in-memory conversation store (history resets when the backend stops)
- the Vite development server and a local FastAPI server

It does **not** require an AWS account, AWS credentials, a domain, an Anthropic API key, or any paid API request. It is not the production deployment path.

## Option A: Docker Desktop

Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and make sure it is running. From the repository root, run:

```bash
docker compose -f docker-compose.local.yml up --build
```

Open [http://localhost:5173](http://localhost:5173). The backend health endpoint is [http://localhost:8000/api/health/live](http://localhost:8000/api/health/live).

Stop the services with `Ctrl+C`. To remove the stopped containers, run:

```bash
docker compose -f docker-compose.local.yml down
```

The compose file has no AWS credentials, cloud secrets, or persistent volumes.

## Option B: Windows PowerShell without Docker

Prerequisites: Python 3.12, [uv](https://docs.astral.sh/uv/getting-started/installation/), and Node.js 24.

From the repository root:

```powershell
Copy-Item .env.example backend/.env
Set-Location backend
uv sync --frozen --python 3.12
uv run uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload --no-access-log
```

Keep that terminal open. In a second PowerShell terminal:

```powershell
Set-Location path\to\claude-aws-devops-platform\frontend
npm ci
npm run dev
```

Open [http://localhost:5173](http://localhost:5173). The copied `backend/.env` is ignored by Git and already enables local auth and mock Claude mode.

## Option C: Git Bash/macOS/Linux without Docker

```bash
cp .env.example backend/.env
(cd backend && uv sync --frozen --python 3.12 && uv run uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload --no-access-log)
```

In another terminal:

```bash
cd frontend
npm ci
npm run dev
```

Open [http://localhost:5173](http://localhost:5173).

## Important boundaries

Do not set `MOCK_CLAUDE=false` unless you have intentionally configured a real Anthropic API key and accept its usage charges. Do not run Terraform for this local exercise: the `infra/` configuration creates AWS resources such as an ALB, NAT gateways, ECS, CloudFront, and DynamoDB that can incur charges. Use [SETUP.md](SETUP.md) only when you are ready for the paid AWS deployment path.
