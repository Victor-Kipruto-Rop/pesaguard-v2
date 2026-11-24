# pesaguard-api

Backend for api.pesaguard.co.ke: FastAPI HTTP API and a Python background worker in one codebase.

This repository is a scaffold. Files tagged in their header comments as [V1], [PRE] or [OPT] are
placeholders describing intent; implement in the build order in the structure document.

## Quick start (local)
1. `cp .env.example .env`
2. `docker compose up -d db`
3. `uv sync`
4. `make migrate`
5. `make dev` (API) and `make worker` (worker) in separate terminals

## Layering
core, db, repositories, integrations, domain, services, schemas, api, workers.
Dependencies point downward only; see docs/architecture/layering-rules.md.
