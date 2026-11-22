# Reusable Workflow Service Contract

> Status: active contract
>
> Last updated: 2026-11-22

This document defines what a service repository must provide when it consumes
the reusable workflows in this public repository.

## Contract Principles

Reusable workflows own common CI/CD mechanics:

- checkout
- runtime setup
- dependency cache wiring
- job timeout defaults
- matrix execution
- artifact upload
- GitHub step summaries
- safe defaults that avoid production side effects

Service repositories own application behavior:

- test commands
- build commands
- artifact packaging commands
- migration commands
- health check paths
- environment names
- deploy target roots
- service unit names
- GitHub Environment secrets and variables
- production approval decisions

## Common Inputs by Family

Exact per-workflow input tables live in `docs/reusable-workflows/*.md`. Across
the 7 reusable workflows, inputs group by family:

### All Reusable Workflows

| Input | Required | Meaning |
|---|---:|---|
| `service_name` | yes | Stable service id used in summaries and artifact names. |
| `artifact_retention_days` | no | Uploaded artifact retention in days (default `14`). |
| `telegram_chat_id` | no | Optional Telegram chat id; empty disables Telegram. |
| `telegram_notify_on` | no | `failure` (default), `always`, or `never` (skips the notify job). |

### Python Family (`*-node-python.yml`, `deploy-*-artifact.yml`, `production-preflight-artifact.yml`)

| Input | Applies to | Meaning |
|---|---|---|
| `python_version` | All Python-family workflows | Python version for backend or verification jobs. |
| `backend_dependency_file` | `pr-ci-node-python.yml`, `release-candidate-node-python.yml`, `deploy-dry-run-artifact.yml` | Pip dependency file used for cache and install. |
| `backend_dir` | `pr-ci-node-python.yml` | Backend source directory. |

### Go Family (`*-go-node.yml`)

| Input | Applies to | Meaning |
|---|---|---|
| `go_version_file` | `pr-ci-go-node.yml`, `release-candidate-go-node.yml` | Path to `go.mod` or version file for `actions/setup-go`. |
| `go_dependency_file` | `pr-ci-go-node.yml`, `release-candidate-go-node.yml` | Path to `go.sum` used for Go module cache key. |

### Node Build Workflows (`pr-ci-*.yml`, `release-candidate-*.yml`, `deploy-dry-run-artifact.yml`)

| Input | Applies to | Meaning |
|---|---|---|
| `node_version` | PR CI, Release Candidate, Deploy Dry Run | Node.js version for frontend jobs. |
| `frontend_lockfile` | PR CI, Release Candidate, Deploy Dry Run | NPM lockfile used for cache. |
| `frontend_dir` | `pr-ci-node-python.yml`, `pr-ci-go-node.yml`, `release-candidate-go-node.yml` | Frontend source directory. |

## Secret Boundary

Reusable workflows may document expected secret names, but secret values must
stay in the consuming repository's GitHub Environments or on target servers.

This public repo must not contain:

- secret values
- `.env` files
- private keys
- database URLs
- tokens
- webhook URLs
- production logs
- customer data

## Migration Rule

When a service migrates from local workflow YAML to reusable workflows:

1. Migrate one workflow family at a time.
2. Test on a branch before changing branch protection.
3. Record exact GitHub check names after the reusable workflow runs.
4. Update branch protection only after the new check names are known and green.
5. Keep production deploy workflows local until the service has proven staging,
   rollback, and production approval behavior.

## Current Reusable Workflows

| Workflow | Status | Secrets | Production impact |
|---|---|---|---|
| `pr-ci-node-python.yml` | active | none | none |
| `pr-ci-go-node.yml` | active | none | none |
| `release-candidate-node-python.yml` | active | none | none |
| `release-candidate-go-node.yml` | active | none | none |
| `deploy-dry-run-artifact.yml` | active | none | none |
| `deploy-staging-artifact.yml` | active for runner-local staging proof | none | none |
| `production-preflight-artifact.yml` | active for runner-local production preflight | none | none unless caller explicitly confirms a read-only health URL |

For self-hosted runner-pool composite actions (`.github/actions/pool-pick` and
`.github/actions/pool-evidence`), see [Pool Actions](../README.md#pool-actions).

Remote SSH staging and real production deploy workflows are intentionally not
part of the current reusable surface. They should be extracted only after the
consuming service has proven staging, rollback, and production approval
behavior.
