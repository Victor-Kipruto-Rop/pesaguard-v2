#!/bin/sh
set -e
case "$1" in
  api)     exec uvicorn pesaguard_api.main:create_app --factory --host 0.0.0.0 --port "${PORT:-8000}" ;;
  worker)  exec python -m pesaguard_api.worker_main ;;
  migrate) exec alembic upgrade head ;;
  cli)     shift; exec python -m pesaguard_api.cli "$@" ;;
  *)       exec "$@" ;;
esac
