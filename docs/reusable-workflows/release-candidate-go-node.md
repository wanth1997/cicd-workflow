# `release-candidate-go-node.yml`

> Status: draft reusable workflow
>
> Last updated: 2026-05-25

Reusable Release Candidate workflow for a service with:

- Go backend test shards
- PostgreSQL migration / schema check
- Node frontend checks
- service-owned release artifact build command

The workflow has no secrets and no deploy behavior.

## Jobs

| Job | Purpose |
|---|---|
| `backend-full-tests` | Run full Go backend test shards from `backend_shards_json`. |
| `backend-migration` | Run fresh PostgreSQL migration and schema check. |
| `frontend-checks` | Run frontend install / lint / tests / build through a service-owned script. |
| `build-release` | Build and upload the release artifact after migration and frontend checks pass. It runs in parallel with backend full-test shards to shorten the Release Candidate critical path. |

`build-release` intentionally does not wait for `backend-full-tests`. The
overall Release Candidate run is still unsuccessful if any full-test shard
fails, so consumers must only deploy artifacts from successful Release
Candidate runs. The reusable staging and production preflight workflows enforce
that check when resolving a release run.

## Wrapper Example

```yaml
jobs:
  release-candidate:
    uses: wanth1997/cicd-workflow/.github/workflows/release-candidate-go-node.yml@v0.6.0
    with:
      service_name: zenincome
      go_version_file: go.mod
      go_dependency_file: go.sum
      node_version: "20"
      frontend_dir: web
      frontend_lockfile: web/package-lock.json
      backend_shards_json: >
        [
          {"shard":"api","suite":"full-api","report":"backend-full-api-go-test.json"}
        ]
      backend_ci_command: ./ops/ci-cd/scripts/run-backend-ci.sh
      migration_check_command: ./ops/ci-cd/scripts/run-backend-migration-check.sh
      frontend_ci_command: ./ops/ci-cd/scripts/run-frontend-ci.sh
      build_release_command: ./ops/ci-cd/build-release.sh
      release_artifact_prefix: zenincome-release-
```
