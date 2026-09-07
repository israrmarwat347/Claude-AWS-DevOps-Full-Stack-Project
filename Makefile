.PHONY: backend frontend test format build
backend:
	cd backend && uv run uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload --no-access-log
frontend:
	cd frontend && npm run dev
test:
	cd backend && uv run ruff check . && uv run ruff format --check . && uv run pytest -q
	cd frontend && npm run lint && npm test
format:
	cd backend && uv run ruff check . --fix && uv run ruff format .
	terraform fmt -recursive
build:
	cd frontend && npm run build
	docker build -f backend/Dockerfile -t claude-platform:local .
