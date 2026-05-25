# `pr-ci-go-node.yml`

> Status: draft reusable workflow
>
> Last updated: 2026-05-25

Reusable PR CI workflow for a service with:

- Go backend
- Node frontend
- ephemeral PostgreSQL migration check
- service-owned test scripts

The workflow has no secrets and no deploy behavior.

## Jobs

| Job | Purpose |
|---|---|
| `backend-fast-tests` | Run the service's fast Go backend test suite. |
| `backend-migration-tests` | Run migration regression tests. |
| `backend-migration` | Run fresh PostgreSQL migration and schema check. |
| `frontend-checks` | Run frontend install / lint / tests / build through a service-owned script. |

## Inputs

| Input | Required | Default |
|---|---:|---|
| `service_name` | yes | |
| `go_version_file` | yes | |
| `go_dependency_file` | yes | |
| `node_version` | yes | |
| `frontend_dir` | yes | |
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

- `<service_name>-backend-fast-go-test-report`
- `<service_name>-backend-migration-go-test-report`

The service-owned backend command should write Go test JSON to the
`GO_TEST_JSON` path provided by the workflow.
