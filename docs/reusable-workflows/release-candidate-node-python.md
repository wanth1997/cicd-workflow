# `release-candidate-node-python.yml`

> Status: active reusable workflow
>
> Last updated: 2026-11-22

Reusable Release Candidate workflow for a service with:

- optional Python backend test shards
- PostgreSQL migration / schema drift check
- Node frontend checks
- service-owned release artifact build command

The workflow has no built-in secrets and no deploy behavior. Optional Telegram
notifications use a caller-provided `telegram_bot_token` secret.

## Jobs

| Job | Purpose |
|---|---|
| `backend-full-tests` | Optionally run full backend test shards from `backend_shards_json`. |
| `backend-migration` | Run fresh PostgreSQL migration and schema drift check. |
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

## Inputs

| Input | Required | Default |
|---|---:|---|
| `service_name` | yes | |
| `python_version` | yes | |
| `node_version` | yes | |
| `backend_dependency_file` | yes | |
| `frontend_lockfile` | yes | |
| `run_backend_full_tests` | no | `true` |
| `backend_shards_json` | yes | |
| `backend_ci_command` | yes | |
| `migration_check_command` | yes | |
| `frontend_ci_command` | yes | |
| `build_release_command` | yes | |
| `release_artifact_prefix` | yes | |
| `postgres_image` | no | `postgres:15` |
| `postgres_db` | no | `app_ci` |
| `postgres_user` | no | `app` |
| `postgres_password` | no | `app` |
| `require_clean` | no | `"1"` |
| `artifact_retention_days` | no | `14` |
| `telegram_chat_id` | no | empty, disables Telegram |
| `telegram_notify_on` | no | `failure` |

## Secrets

| Secret | Required | Purpose |
|---|---:|---|
| `telegram_bot_token` | no | Service repo Telegram bot token used only when `telegram_chat_id` is set. |

## Telegram Notifications

When enabled, the final `notify-telegram` job sends one concise status message
with repo, stage, workflow, status, branch, commit title plus short SHA, release
id when available, job results, action guidance, and the GitHub Run URL.
Set `telegram_chat_id` from a service repo variable and pass
`telegram_bot_token` from a service repo secret. `telegram_notify_on` accepts
`failure`, `always`, or `never`.

## Output Artifacts

- `<release_artifact_prefix><release_id>` (release directory built by `build_release_command`)
- `<service_name>-backend-full-<shard>-pytest-report` when `run_backend_full_tests` is true (`PYTEST_JUNIT_XML`)

## Wrapper Example

```yaml
jobs:
  release-candidate:
    uses: wanth1997/cicd-workflow/.github/workflows/release-candidate-node-python.yml@v0.11.1
    with:
      service_name: ppclub
      python_version: "3.11"
      node_version: "24"
      backend_dependency_file: backend/requirements.txt
      frontend_lockfile: frontend/package-lock.json
      run_backend_full_tests: false
      backend_shards_json: >
        [
          {"shard":"rest","suite":"full-rest","report":"backend-full-rest-pytest.xml"}
        ]
      backend_ci_command: ./ops/ci-cd/scripts/run-backend-ci.sh
      migration_check_command: ./ops/ci-cd/scripts/run-backend-migration-check.sh
      frontend_ci_command: ./ops/ci-cd/scripts/run-frontend-ci.sh
      build_release_command: ./ops/ci-cd/build-release.sh
      release_artifact_prefix: ppclub-release-
      telegram_chat_id: ${{ vars.TELEGRAM_CHAT_ID }}
      telegram_notify_on: failure
    secrets:
      telegram_bot_token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
```
