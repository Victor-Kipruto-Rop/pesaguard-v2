.PHONY: dev worker test lint typecheck migrate seed openapi
dev:
	uv run uvicorn pesaguard_api.main:create_app --factory --reload
worker:
	uv run python -m pesaguard_api.worker_main
test:
	uv run pytest --cov
lint:
	uv run ruff check . && uv run ruff format --check .
typecheck:
	uv run mypy
migrate:
	uv run alembic upgrade head
seed:
	uv run python scripts/seed_dev_data.py
openapi:
	uv run python scripts/export_openapi.py
