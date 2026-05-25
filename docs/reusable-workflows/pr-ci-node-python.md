# `pr-ci-node-python.yml`

> Status: draft reusable workflow
>
> Last updated: 2026-05-25

Reusable PR CI workflow for a service with:

- Python backend
- Node frontend
- ephemeral PostgreSQL migration check
- service-owned test scripts
- optional full backend test shards for PR merge gates

The workflow has no built-in secrets and no deploy behavior. Optional Telegram
notifications use a caller-provided `telegram_bot_token` secret.

## Jobs

| Job | Purpose |
|---|---|
| `backend-fast-tests` | Run the service's fast backend test suite. |
| `backend-migration-tests` | Run migration regression tests. |
| `backend-full-tests` | Optionally run full backend test shards from `backend_full_shards_json`. |
| `backend-migration` | Run fresh PostgreSQL migration and schema drift check. |
| `frontend-checks` | Run frontend install / lint / tests / build through a service-owned script. |

## Inputs

| Input | Required | Default |
|---|---:|---|
| `service_name` | yes | |
| `python_version` | yes | |
| `node_version` | yes | |
| `backend_dir` | yes | |
| `frontend_dir` | yes | |
| `backend_dependency_file` | yes | |
| `frontend_lockfile` | yes | |
| `backend_fast_suite` | yes | |
| `backend_migration_suite` | yes | |
| `run_backend_full_tests` | no | `false` |
| `backend_full_shards_json` | no | `[]` |
| `backend_ci_command` | yes | |
| `migration_check_command` | yes | |
| `frontend_ci_command` | yes | |
| `postgres_image` | no | `postgres:15` |
| `postgres_db` | no | `app_ci` |
| `postgres_user` | no | `app` |
| `postgres_password` | no | `app` |
| `artifact_retention_days` | no | `14` |
| `telegram_chat_id` | no | empty, disables Telegram |
| `telegram_notify_on` | no | `failure` |

## Secrets

| Secret | Required | Purpose |
|---|---:|---|
| `telegram_bot_token` | no | Service repo Telegram bot token used only when `telegram_chat_id` is set. |

## Telegram Notifications

When enabled, the final `notify-telegram` job sends one concise status message
with repo, stage, workflow, status, branch, commit title plus short SHA, job
results, action guidance, and the GitHub Run URL. `telegram_notify_on` accepts
`failure`, `always`, or `never`.

## Output Artifacts

- `<service_name>-backend-fast-pytest-report`
- `<service_name>-backend-migration-pytest-report`
- `<service_name>-backend-full-<shard>-pytest-report` when `run_backend_full_tests` is true

The service-owned backend command should write JUnit XML to the
`PYTEST_JUNIT_XML` path provided by the workflow.

For a protected default branch, PR CI should own the full merge gate: set
`run_backend_full_tests: true` and provide `backend_full_shards_json` in the
service wrapper. Main-branch push workflows can then skip repeated backend full
test shards and focus on release artifact checks.

## Wrapper Example

See [`examples/pr-ci-wrapper.yml`](../../examples/pr-ci-wrapper.yml).
