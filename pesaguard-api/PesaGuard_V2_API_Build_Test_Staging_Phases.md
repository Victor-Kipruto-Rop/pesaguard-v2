# PesaGuard V2 API: Build, Test and Staging Phases

Repository: `pesaguard-api` (serves `api.pesaguard.co.ke`). One codebase, two processes: HTTP API and background worker.

Tags used in the structure document: **[V1]** needed for a working reconciliation workflow in sandbox and staging, **[PRE]** needed before production onboarding, **[OPT]** optional or scope-dependent.

**Scope of this plan:** building, testing and staging. Production activation is listed only as a final gate, because it depends on external approvals (Safaricom production access, verified email domain) that are not assumed to exist.

**Rules that apply to every phase**

- A phase is finished only when its exit criteria are all met. Do not start the next phase early.
- No real credentials in Git, logs, chat or documents. Sandbox values only until production approval.
- Every pull request: tests pass, migrations reviewed, tenant scoping checked, `.env.example` updated if configuration changed.
- Layering rules are enforced by `tests/architecture/test_import_boundaries.py` from Phase 1 onward.

---

## Overview

| Stage | Phase | Goal | Main output |
|---|---|---|---|
| Build | B0 | Workstation, accounts, repository | Working local toolchain |
| Build | B1 | Foundation | App boots, health endpoints, CI green |
| Build | B2 | Data model and queue | Migrations, repositories, job table |
| Build | B3 | Daraja C2B ingestion | Callbacks persisted safely and idempotently |
| Build | B4 | Reconciliation engine | Rules, matching, exceptions |
| Build | B5 | Dashboard API | Auth, tenants, search, exports, OpenAPI |
| Build | B6 | Hardening for production readiness | All [PRE] code complete |
| Test | T1 | Unit tests | Pure logic proven |
| Test | T2 | Integration tests | Database, queue, idempotency proven |
| Test | T3 | API and contract tests | Endpoints and OpenAPI contract proven |
| Test | T4 | Security and tenant isolation tests | No cross-tenant access, no secret leakage |
| Test | T5 | Reliability and load checks | Measured baselines |
| Staging | S1 | Staging infrastructure | Render and Cloudflare staging live |
| Staging | S2 | First deployment and migration | Release running on staging |
| Staging | S3 | Daraja sandbox end-to-end | Real sandbox callbacks reconciled |
| Staging | S4 | Dashboard integration | Frontend works against staging API |
| Staging | S5 | Operational rehearsal | Rollback, restore, dead-letter, monitoring drills |
| Staging | S6 | Staging sign-off | Go/no-go for production preparation |

Testing is not a single block after building: unit tests are written with each build phase, and phases T1 to T5 define the full test coverage required by the end of each stage. The order below is the order of execution.

---

# STAGE 1: BUILDING

## Phase B0: Prerequisites and workstation

**Goal:** a developer can clone, install and run the project locally.

Tasks

- [ ] Install on the Ubuntu workstation: Git, Docker Engine and Compose plugin, `uv`, Node LTS and pnpm (for the frontend later), VS Code, `psql`, Bruno.
- [ ] Create accounts: GitHub organisation, Cloudflare, Render, Safaricom Daraja developer account (sandbox), Sentry (can wait until B6).
- [ ] Create the GitHub repository `pesaguard-api`; enable branch protection on `main` (required reviews and required status checks).
- [ ] Unzip the scaffold into the repository; run `uv lock` to replace the placeholder `uv.lock`; commit.
- [ ] Copy `.env.example` to `.env`; start the database with `docker compose up -d db`.
- [ ] Create a Daraja sandbox app and note the sandbox shortcode and keys in the local secret store (never in Git).

Files touched: `.env.example`, `docker-compose.yml`, `docker/postgres/init.sql`, `pyproject.toml`, `uv.lock`, `README.md`, `.github/pull_request_template.md`.

Exit criteria

- [ ] `uv sync` completes; `docker compose up -d db` shows a healthy database.
- [ ] A new developer follows `README.md` and gets a running database without help.
- [ ] Branch protection is active on `main`.

---

## Phase B1: Foundation

**Goal:** the application starts, logs correctly, fails fast on bad configuration, and CI runs.

Tasks

- [ ] `core/config.py`: typed settings; the app refuses to start if a required variable is missing or invalid.
- [ ] `core/logging.py`: JSON logs with redaction of secrets and MSISDN values.
- [ ] `core/errors.py`, `core/error_handlers.py`: stable error codes and one error response envelope.
- [ ] `core/request_context.py`, `core/middleware/*`: request ID, access log without bodies, security headers, body size limit.
- [ ] `core/money.py`, `core/phone.py`, `core/ids.py`, `core/time.py`: small utilities, with unit tests.
- [ ] `db/base.py`, `db/session.py`, `db/mixins.py`: SQLAlchemy base, naming convention, unit-of-work.
- [ ] `observability/health_checks.py`, `api/health.py`: `/health/live` (process only) and `/health/ready` (database and Alembic revision).
- [ ] `main.py`: `create_app()` factory; `worker_main.py`: empty runner that starts and stops cleanly.
- [ ] Alembic wired in `migrations/env.py`; `scripts/check_migration_heads.py`.
- [ ] `.github/workflows/ci.yml`: ruff, mypy, pytest with a Postgres service, coverage, image build.
- [ ] `tests/architecture/test_import_boundaries.py` enforcing layering rules.

Exit criteria

- [ ] `make dev` serves `/health/live` and `/health/ready`; stopping the database makes ready fail while live still passes.
- [ ] CI is green on a pull request and blocks merge when a check fails.
- [ ] Unit tests for config, money, phone, errors, and log redaction pass.
- [ ] Docker image builds and runs as a non-root user.

---

## Phase B2: Data model, repositories and job queue

**Goal:** the persistent core exists, with tenant scoping and the queue.

Tasks

- [ ] Migrations `0001` to `0008`: tenancy and auth tables, merchant accounts, raw events and transactions (unique key on tenant plus provider transaction ID), expected records and imports, reconciliation, exceptions, jobs, leads.
- [ ] `db/models/*`: models for all tables above. No secret values stored in `merchant_account`; store references only.
- [ ] `core/tenancy.py` and `repositories/base.py`: every repository call requires a `TenantContext`; unscoped methods are few, named and reviewed.
- [ ] `repositories/*`: tenants, users, memberships, sessions, invitations, merchants, raw events, transactions, expected records, import batches, reconciliation, exceptions, jobs, leads.
- [ ] `repositories/jobs.py`: enqueue, claim using `FOR UPDATE SKIP LOCKED`, lease, heartbeat, complete, fail; uniqueness on (job type, idempotency key) for active jobs.
- [ ] `workers/queue.py`, `workers/retry.py`, `workers/registry.py`, `workers/runner.py`: poll loop, graceful shutdown, backoff with jitter, dead status after maximum attempts.
- [ ] `scripts/seed_dev_data.py`: fake tenants, users, merchants and transactions.

Exit criteria

- [ ] `alembic upgrade head` succeeds on an empty database; a single Alembic head exists.
- [ ] Two workers running concurrently never claim the same job (test in T2).
- [ ] A transient failure retries with growing delay; a permanent failure goes straight to dead.
- [ ] Repository tests prove the tenant filter is applied on every tenant-owned table.

---

## Phase B3: Daraja C2B ingestion

**Goal:** sandbox callbacks are accepted, stored safely once, and queued for processing.

Tasks

- [ ] `schemas/daraja/common.py`, `schemas/daraja/c2b.py`: payload models; reject malformed and unexpected types.
- [ ] `integrations/daraja/client.py`, `auth.py`, `c2b.py`, `errors.py`: HTTPX client with explicit timeouts, OAuth token cache, C2B URL registration.
- [ ] `api/webhooks/daraja_c2b.py`: validation and confirmation endpoints; check path token and body size; no processing in the handler.
- [ ] `services/ingestion_service.py`: one transaction that writes the raw event, the normalised transaction and the job; a unique-key violation is treated as a duplicate (counted, duplicate raw payload stored, success acknowledged); a duplicate with different details becomes an exception, not a silent drop.
- [ ] `domain/mpesa/normalise.py`, `domain/mpesa/result_codes.py`: payload to normalised transaction.
- [ ] `workers/handlers/process_raw_event.py`: validate, normalise, enqueue reconciliation.
- [ ] `cli.py`: `register-c2b-urls` command for sandbox registration.
- [ ] Callback fixtures in `tests/fixtures/daraja/` and Bruno requests in `bruno/daraja/`.
- [ ] STK Push files (`stk.py`, `stk_state.py`, `query_stk_status.py`) are built **only if** STK Push is inside the approved V1 scope.

Exit criteria

- [ ] Valid callback: stored once, job created, acknowledgement returned quickly.
- [ ] Same callback sent twice: still one transaction, duplicate counted, both raw payloads kept.
- [ ] Malformed, wrong-shortcode and wrong-token requests are rejected and logged without secrets.
- [ ] The handler never performs reconciliation work itself.

---

## Phase B4: Reconciliation engine

**Goal:** stored transactions are matched against merchant expectations, and differences become exceptions.

Tasks

- [ ] `domain/reconciliation/engine.py`, `matcher.py`, `states.py`, `exception_types.py`: pure functions, no I/O.
- [ ] Rules in `domain/reconciliation/rules/`: exact reference, amount and time window, partial payment, duplicate detection, over and under payment. Rules are ordered and deterministic.
- [ ] `services/import_service.py`, `api/v1/imports.py`: load expected records from file with row-level validation and a rejected-rows report.
- [ ] `services/reconciliation_service.py`: start runs, apply engine results, write matches and exceptions.
- [ ] `workers/handlers/run_reconciliation.py`.
- [ ] `services/exception_service.py`: assign, comment, resolve, reopen with allowed state transitions.
- [ ] Distinct states kept in the data model: received, validated, matched, exception, resolved. A received callback is never treated as reconciled.

Exit criteria

- [ ] Running the same reconciliation twice produces the same result (idempotent).
- [ ] Each rule has tests for match, no match and edge cases (rounding, timing boundary, multiple candidates).
- [ ] A transaction with no expected record appears as an exception, not as matched.

---

## Phase B5: Dashboard API

**Goal:** everything the customer dashboard needs is available through typed, authenticated endpoints.

Tasks

- [ ] `core/security/passwords.py`, `sessions.py`, `csrf.py`, `permissions.py`: Argon2 hashing, server-side sessions in an httpOnly Secure cookie, CSRF protection, role-based permissions.
- [ ] `api/deps.py`: database session, current user, tenant context and permission dependencies.
- [ ] `api/v1/auth.py`, `users.py`, `tenants.py`, `merchants.py`: login, logout, current user, invitations, tenant settings, merchant accounts.
- [ ] `api/v1/transactions.py`: search, filter, detail with bounded page size.
- [ ] `api/v1/reconciliation.py`, `exceptions.py`: trigger runs, list results, investigate exceptions.
- [ ] `api/v1/reports.py`: summaries and streamed CSV export (no server-side file storage in V1).
- [ ] `api/v1/leads.py`: public Request Demo endpoint with input validation; internal notification email via the demo template.
- [ ] `scripts/export_openapi.py`; commit `openapi/openapi.json`; CI fails if it drifts from the generated schema.
- [ ] Hand the OpenAPI file to the frontend team for client generation.

Exit criteria

- [ ] Login, logout and session rotation work; a request without a CSRF token on a state-changing route is refused.
- [ ] A user in tenant A cannot read or change tenant B data through any endpoint (full proof comes in T4).
- [ ] The committed OpenAPI file matches the app.

---

## Phase B6: Hardening for production readiness

**Goal:** all [PRE] code exists, so production onboarding is limited to external activation.

Tasks

- [ ] `core/telemetry.py`: Sentry and OpenTelemetry initialisation (no-op when unset); PII capture disabled.
- [ ] `observability/metrics.py`: callbacks persisted, rejected and duplicate counts, oldest job age, dead job count, unmatched ratio.
- [ ] `core/rate_limit.py`: limits on public, auth and callback routes.
- [ ] `services/audit_service.py`, `repositories/audit.py`, `api/v1/audit.py`: append-only audit of sensitive actions.
- [ ] `core/security/tokens.py`, `account_recovery_service.py`, `api/v1/account_recovery.py`: email verification and password reset with hashed tokens.
- [ ] `integrations/resend/*`, `emails/*`, `workers/handlers/send_email.py`, `process_resend_event.py`, `api/webhooks/resend.py`: sending, signed webhook verification on the raw body, bounce and complaint handling.
- [ ] `workers/scheduler.py`, `heartbeat.py`, `handlers/detect_callback_gaps.py`, `purge_expired.py`: gap detection, lease reclaim, retention, worker liveness.
- [ ] `integrations/daraja/transaction_status.py`, `security_credential.py`: for investigation of missing callbacks.
- [ ] `api/v1/notifications.py`, `api/v1/admin.py`: preferences and internal operations.
- [ ] `.github/workflows/security.yml`, `dependabot.yml`, `CODEOWNERS`, `SECURITY.md`.
- [ ] Runbooks in `docs/runbooks/`: deploy and rollback, restore database, dead-letter replay, missing callbacks, secret rotation, incident response.
- [ ] Optional if justified: Row-Level Security, API keys, application-level field encryption.

Exit criteria

- [ ] Every [PRE] file in the structure document is implemented or explicitly deferred with a recorded reason.
- [ ] Runbooks exist and are readable by someone who did not write them.

---

# STAGE 2: TESTING

Tests are written alongside the build phases; these phases define what must be proven, in order. Run the full suite in CI on every pull request.

## Phase T1: Unit tests

**Goal:** pure logic is correct and fast to verify.

Scope

- [ ] `tests/unit/core/`: config validation, money (Decimal only, no floats), MSISDN handling, password hashing, permissions, error mapping.
- [ ] `tests/unit/domain/`: normalisation, result codes, reconciliation engine, each rule, state transitions.
- [ ] `tests/unit/integrations/`: Daraja client with mocked HTTP (success, 4xx, 5xx, timeout), token cache expiry, Resend signature verification (valid, wrong secret, expired timestamp, tampered body).

Exit criteria

- [ ] All unit tests pass in under a few minutes with no network and no database.
- [ ] Coverage target is agreed by the team and enforced in CI (suggested starting point: high coverage for `domain/` and `core/`).

## Phase T2: Integration tests (real PostgreSQL)

**Goal:** database behaviour, constraints and the queue are proven.

Scope

- [ ] `test_migrations_upgrade.py`: clean upgrade to head; exactly one head.
- [ ] `test_repositories.py`: CRUD and tenant filter on every tenant-owned table.
- [ ] `test_ingestion_idempotency.py`: duplicate callbacks create one transaction; differing duplicates raise an exception case.
- [ ] `test_queue_claiming.py`: concurrent workers never claim the same job; expired leases are reclaimed.
- [ ] `tests/workers/`: retry policy, dead-letter behaviour, `process_raw_event`, `run_reconciliation`, gap detection.
- [ ] Use PostgreSQL, not SQLite; each test runs in a rolled-back transaction.

Exit criteria

- [ ] No flaky tests: the suite passes repeatedly (for example ten consecutive runs).
- [ ] A forced crash of a worker mid-job results in the job being retried exactly once after lease expiry.

## Phase T3: API and contract tests

**Goal:** endpoints behave as documented.

Scope

- [ ] `test_health.py`: live independent of database; ready dependent on it.
- [ ] `test_auth_flow.py`, `test_csrf.py`.
- [ ] `test_c2b_callbacks.py`: accept, reject, duplicate, malformed, wrong token, oversized body.
- [ ] `test_transactions_api.py`, `test_reconciliation_api.py`, `test_exceptions_api.py`, `test_exports.py`.
- [ ] `test_resend_webhook.py`, `test_leads_rate_limit.py`.
- [ ] `test_openapi_contract.py`: committed schema equals generated schema.
- [ ] Bruno collection runs against a local instance for manual regression.

Exit criteria

- [ ] Every endpoint has at least one success and one failure test, including authorisation failure.
- [ ] Error responses always use the standard envelope with a stable error code.

## Phase T4: Security and tenant isolation tests

**Goal:** prove the controls that protect customer data.

Scope

- [ ] `test_tenant_isolation_db.py` and `test_tenant_isolation_api.py`: for every tenant-owned resource, tenant A cannot list, read, update or delete tenant B data, including by guessing IDs.
- [ ] `test_log_redaction.py`: secrets and MSISDN never appear in logs, including on error paths.
- [ ] `test_security_headers.py`.
- [ ] Dependency and static scanning in CI: Bandit, `pip-audit`, container image scan, secret scanning.
- [ ] Review: no secrets in Git history, no secret-bearing variables exposed in responses or OpenAPI examples.
- [ ] Callback trust model reviewed against `docs/adr/0004-daraja-callback-trust-model.md`.

Exit criteria

- [ ] Zero cross-tenant access in the isolation suite.
- [ ] No high-severity unresolved findings from scanners; accepted findings are recorded with a reason.

## Phase T5: Reliability and load checks

**Goal:** establish measured baselines. These numbers justify (or rule out) later changes such as extra indexes, pooling or a different queue.

Scope

- [ ] Replay a burst of sandbox-shaped callbacks and record: acknowledgement latency, ingest-to-reconciled latency, queue depth and oldest job age.
- [ ] Run `EXPLAIN ANALYZE` on the hot queries (transaction search, reconciliation matching, job claiming); add an index only when a scan is shown to be the problem.
- [ ] Failure injection: stop the database during traffic; kill a worker; return errors from a mocked Daraja or Resend; confirm no data loss and correct retries.
- [ ] Record the results in `docs/architecture/` for later comparison.

Exit criteria

- [ ] Baseline numbers are recorded.
- [ ] No lost callbacks and no duplicate transactions under failure injection.

---

# STAGE 3: STAGING

## Phase S1: Staging infrastructure

**Goal:** an isolated staging environment exists and is configured.

Tasks

- [ ] Render: managed PostgreSQL (staging), API web service, background worker, all from the same image; health check on `/health/ready`.
- [ ] Separate database roles for API and worker (least privilege).
- [ ] Render environment variables and secrets set for staging, using sandbox Daraja values only; `DARAJA_CALLBACK_PATH_TOKEN` generated fresh.
- [ ] Cloudflare: DNS record and proxy for the staging API host (for example `api-staging`); TLS verified.
- [ ] Cloudflare Pages staging project for the dashboard (frontend team).
- [ ] Optional: `render.yaml` Blueprint to declare the services.
- [ ] GitHub Actions: `deploy-staging.yml` configured to trigger the Render deploy after CI passes; migrations run before the new version takes traffic.
- [ ] Sentry staging project and environment tag (if already created).

Exit criteria

- [ ] An empty deployment of the current `main` is reachable over HTTPS; `/health/live` and `/health/ready` pass.
- [ ] No production values exist in staging; no staging values are reused later in production.

## Phase S2: First deployment and migration

**Goal:** the release pipeline works end to end.

Tasks

- [ ] Merge to `main`; confirm CI then automatic staging deploy.
- [ ] Confirm migrations ran once and the schema is at the expected head (`/health/ready` reports ready).
- [ ] Run `scripts/seed_dev_data.py` equivalent for staging with fake data only (a staging-safe variant).
- [ ] Confirm API and worker logs are structured JSON and contain no secrets.
- [ ] Run `tests/smoke/test_staging_smoke.py` against staging.

Exit criteria

- [ ] A deliberate failing migration or build leaves the previous version running.
- [ ] Smoke tests pass after every staging deployment.

## Phase S3: Daraja sandbox end to end

**Goal:** real sandbox callbacks reach staging and are reconciled.

Tasks

- [ ] Register the staging C2B validation and confirmation URLs with the Daraja sandbox.
- [ ] Simulate C2B payments through the sandbox; confirm callbacks arrive at staging.
- [ ] Load matching expected records through the import endpoint; confirm transactions are matched.
- [ ] Send a payment with no expected record; confirm an exception is created.
- [ ] Re-send the same notification; confirm exactly one transaction.
- [ ] Simulate a missing or delayed callback; investigate using the missing-callbacks runbook and record whether any gap-detection alert fired.
- [ ] STK Push scenarios (success, cancelled, timeout) **only if** STK Push is in the approved V1 scope.
- [ ] Record observed payload differences from fixtures and update fixtures and models accordingly.

Exit criteria

- [ ] At least one full path demonstrated: sandbox payment, callback persisted, job processed, reconciled or exception raised, visible through the API.
- [ ] Fixtures match what the sandbox actually sends.

Note: success in the sandbox does not prove production access or approval. Production Daraja credentials and callback registration remain separate, external steps.

## Phase S4: Dashboard integration

**Goal:** the frontend works against staging.

Tasks

- [ ] Confirm CORS and cookie settings between `app` staging and `api` staging hosts (shared registrable domain, `Secure`, correct `SameSite`).
- [ ] Generate the TypeScript client from the staging OpenAPI file; confirm the frontend build passes type checking.
- [ ] Walk through: login, transaction search, filters, reconciliation results, exception investigation, CSV export, logout.
- [ ] Run the frontend Playwright suite against staging.
- [ ] Submit the public Request Demo form from the staging website; confirm storage and the internal notification path (console or captured email unless Resend is configured).

Exit criteria

- [ ] End-to-end flows pass in a real browser against staging.
- [ ] No browser console errors about CORS, cookies or CSRF.

## Phase S5: Operational rehearsal

**Goal:** operational procedures are proven before anyone depends on them.

Tasks

- [ ] **Rollback:** deploy a known-bad version to staging, then roll back; confirm data remains consistent and migrations were backward compatible for one release.
- [ ] **Backup and restore:** take a backup; restore into a scratch database with `scripts/restore_drill.sh`; run sanity queries; record the time taken.
- [ ] **Dead-letter replay:** force a permanent failure, confirm the job is dead and alerts, then replay with `scripts/replay_dead_jobs.py` (dry run first).
- [ ] **Monitoring:** confirm Sentry receives a deliberate test exception; confirm OpenTelemetry traces and metrics arrive if configured; set up an external uptime check on staging `/health/ready`.
- [ ] **Business alerts:** confirm alerts fire for a worker stopped (oldest job age), dead jobs, callback gap, and unusual rejection counts.
- [ ] **Secret rotation:** rotate one non-critical secret on staging following the runbook; confirm services recover.
- [ ] **Email (if configured):** send a verification email through a verified sending domain; confirm SPF, DKIM and DMARC alignment; trigger a bounce event and confirm webhook handling.

Exit criteria

- [ ] Every runbook step was executed at least once on staging and corrected where it was wrong.
- [ ] Time to roll back and time to restore are recorded.

## Phase S6: Staging sign-off

**Goal:** a clear go/no-go decision on moving to production preparation.

Checklist

- [ ] All exit criteria of phases B0 to B6, T1 to T5 and S1 to S5 are met, or deviations are written down and accepted.
- [ ] CI is green; the OpenAPI file is current; no open high-severity security findings.
- [ ] Baseline measurements are recorded and no performance work is pending without evidence.
- [ ] Open items list is written: what is deferred, why, and the measurable condition for revisiting it (Kafka, Kubernetes, microservices, read replicas, Redis queue and the others in the addendum).
- [ ] Owner sign-off from engineering and from the person accountable for the customer data.

Result: **Go** moves the project to production preparation. **No-go** returns to the earliest phase containing an unmet exit criterion.

---

# AFTER STAGING: PRODUCTION GATES (for reference only)

These are outside this plan and are not assumed complete.

- Safaricom production approval, production Daraja credentials and callback registration.
- Verified production email sending domain (SPF, DKIM, DMARC).
- Production Render services on plans with backups, and a tested production restore.
- Production Sentry, OpenTelemetry and external uptime monitoring with alert routing.
- Production secrets created fresh; none copied from staging or developer machines.
- Incident response and rollback procedures assigned to named people.
- Manual promotion of the exact commit that passed staging (`deploy-production.yml`).
