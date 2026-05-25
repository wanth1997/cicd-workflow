# `release-candidate-go-node.yml`

> Status: draft reusable workflow
>
> Last updated: 2026-05-25

Reusable Release Candidate workflow for a service with:

- optional Go backend test shards
- PostgreSQL migration / schema check
- Node frontend checks
- service-owned release artifact build command

The workflow has no built-in secrets and no deploy behavior. Optional Telegram
notifications use a caller-provided `telegram_bot_token` secret.

## Jobs

| Job | Purpose |
|---|---|
| `backend-full-tests` | Optionally run full Go backend test shards from `backend_shards_json`. |
| `backend-migration` | Run fresh PostgreSQL migration and schema check. |
| `frontend-checks` | Run frontend install / lint / tests / build through a service-owned script. |
| `build-release` | Build and upload the release artifact after migration and frontend checks pass. When backend full shards are enabled, it runs in parallel with them to shorten the Release Candidate critical path. |

`run_backend_full_tests` defaults to `true` for backward compatibility. Service
wrappers that run automatically on protected `main` pushes can set it to
`false` after PR CI owns full backend testing. When full shards are enabled,
`build-release` intentionally does not wait for `backend-full-tests`. The
overall Release Candidate run is still unsuccessful if any full-test shard
fails, so consumers must only deploy artifacts from successful Release
Candidate runs. The reusable staging and production preflight workflows enforce
that check when resolving a release run.

## Telegram Notifications

When enabled, the final `notify-telegram` job sends one concise status message
with repo, stage, workflow, status, branch, commit title plus short SHA, release
id when available, job results, action guidance, and the GitHub Run URL.
Set `telegram_chat_id` from a service repo variable and pass
`telegram_bot_token` from a service repo secret. `telegram_notify_on` accepts
`failure`, `always`, or `never`.

## Wrapper Example

```yaml
jobs:
  release-candidate:
    uses: wanth1997/cicd-workflow/.github/workflows/release-candidate-go-node.yml@v0.7.0
    with:
      service_name: zenincome
      go_version_file: go.mod
      go_dependency_file: go.sum
      node_version: "20"
      frontend_dir: web
      frontend_lockfile: web/package-lock.json
      run_backend_full_tests: false
      backend_shards_json: >
        [
          {"shard":"api","suite":"full-api","report":"backend-full-api-go-test.json"}
        ]
      backend_ci_command: ./ops/ci-cd/scripts/run-backend-ci.sh
      migration_check_command: ./ops/ci-cd/scripts/run-backend-migration-check.sh
      frontend_ci_command: ./ops/ci-cd/scripts/run-frontend-ci.sh
      build_release_command: ./ops/ci-cd/build-release.sh
      release_artifact_prefix: zenincome-release-
      telegram_chat_id: ${{ vars.TELEGRAM_CHAT_ID }}
      telegram_notify_on: failure
    secrets:
      telegram_bot_token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
```
