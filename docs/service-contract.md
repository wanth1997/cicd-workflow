# Reusable Workflow Service Contract

> Status: draft contract
>
> Last updated: 2026-05-22

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

## Required Common Inputs

| Input | Meaning |
|---|---|
| `service_name` | Stable service id used in summaries and artifact names. |
| `python_version` | Python version for backend jobs. |
| `node_version` | Node.js version for frontend jobs. |
| `backend_dir` | Backend source directory. |
| `frontend_dir` | Frontend source directory. |
| `backend_dependency_file` | Pip dependency file used for cache and install. |
| `frontend_lockfile` | NPM lockfile used for cache. |

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

Remote SSH staging and real production deploy workflows are intentionally not
part of the current reusable surface. They should be extracted only after the
consuming service has proven staging, rollback, and production approval
behavior.
