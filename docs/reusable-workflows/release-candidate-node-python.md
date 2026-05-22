# `release-candidate-node-python.yml`

> Status: draft reusable workflow
>
> Last updated: 2026-05-22

Reusable Release Candidate workflow for a service with:

- Python backend test shards
- PostgreSQL migration / schema drift check
- Node frontend checks
- service-owned release artifact build command

The workflow has no secrets and no deploy behavior.

## Jobs

| Job | Purpose |
|---|---|
| `backend-full-tests` | Run full backend test shards from `backend_shards_json`. |
| `backend-migration` | Run fresh PostgreSQL migration and schema drift check. |
| `frontend-checks` | Run frontend install / lint / tests / build through a service-owned script. |
| `build-release` | Build and upload the release artifact after checks pass. |

## Wrapper Example

```yaml
jobs:
  release-candidate:
    uses: wanth1997/cicd-workflow/.github/workflows/release-candidate-node-python.yml@v0.2.0
    with:
      service_name: ppclub
      python_version: "3.11"
      node_version: "24"
      backend_dependency_file: backend/requirements.txt
      frontend_lockfile: frontend/package-lock.json
      backend_shards_json: >
        [
          {"shard":"rest","suite":"full-rest","report":"backend-full-rest-pytest.xml"}
        ]
      backend_ci_command: ./ops/ci-cd/scripts/run-backend-ci.sh
      migration_check_command: ./ops/ci-cd/scripts/run-backend-migration-check.sh
      frontend_ci_command: ./ops/ci-cd/scripts/run-frontend-ci.sh
      build_release_command: ./ops/ci-cd/build-release.sh
      release_artifact_prefix: ppclub-release-
```
