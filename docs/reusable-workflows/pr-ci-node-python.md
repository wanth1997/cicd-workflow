# `pr-ci-node-python.yml`

> Status: draft reusable workflow
>
> Last updated: 2026-05-22

Reusable PR CI workflow for a service with:

- Python backend
- Node frontend
- ephemeral PostgreSQL migration check
- service-owned test scripts

The workflow has no secrets and no deploy behavior.

## Jobs

| Job | Purpose |
|---|---|
| `backend-fast-tests` | Run the service's fast backend test suite. |
| `backend-migration-tests` | Run migration regression tests. |
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
| `backend_ci_command` | yes | |
| `migration_check_command` | yes | |
| `frontend_ci_command` | yes | |
| `postgres_image` | no | `postgres:15` |
| `postgres_db` | no | `app_ci` |
| `postgres_user` | no | `app` |
| `postgres_password` | no | `app` |
| `artifact_retention_days` | no | `14` |

## Output Artifacts

- `<service_name>-backend-fast-pytest-report`
- `<service_name>-backend-migration-pytest-report`

The service-owned backend command should write JUnit XML to the
`PYTEST_JUNIT_XML` path provided by the workflow.

## Wrapper Example

See [`examples/pr-ci-wrapper.yml`](../../examples/pr-ci-wrapper.yml).
