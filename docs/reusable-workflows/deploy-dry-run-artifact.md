# `deploy-dry-run-artifact.yml`

> Status: active reusable workflow
>
> Last updated: 2026-11-22

Reusable deploy dry-run workflow for building a release artifact and installing
it into an ephemeral GitHub runner target.

The workflow has no built-in secrets, no remote server access, and no
production behavior. Optional Telegram notifications use a caller-provided
`telegram_bot_token` secret.

## Jobs

| Job | Purpose |
|---|---|
| `deploy-dry-run` | Optionally run fast backend tests, build a release artifact, install it locally, verify manifest / audit shape, and upload dry-run artifacts. |

## Inputs

| Input | Required | Default |
|---|---:|---|
| `service_name` | yes | |
| `python_version` | yes | |
| `node_version` | yes | |
| `backend_dependency_file` | yes | |
| `frontend_lockfile` | yes | |
| `run_backend_fast_tests` | no | `true` |
| `backend_fast_suite` | yes | |
| `backend_ci_command` | yes | |
| `build_release_command` | yes | |
| `release_install_command` | yes | |
| `dry_run_target_root` | no | `.artifacts/deploy-target` |
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
id when available, job result, action guidance, and the GitHub Run URL.
Set `telegram_chat_id` from a service repo variable and pass
`telegram_bot_token` from a service repo secret. `telegram_notify_on` accepts
`failure`, `always`, or `never`.

## Output Artifacts

- `<service_name>-deploy-dry-run-<release_id || run_id>`, containing the built
  release directory, installed `release-manifest.json`, `deploy-audit.json`,
  and `.artifacts/ci/deploy-dry-run-backend-fast.xml` (when fast tests run)

## Wrapper Example

```yaml
jobs:
  deploy-dry-run:
    uses: wanth1997/cicd-workflow/.github/workflows/deploy-dry-run-artifact.yml@v0.11.1
    with:
      service_name: ppclub
      python_version: "3.11"
      node_version: "24"
      backend_dependency_file: backend/requirements.txt
      frontend_lockfile: frontend/package-lock.json
      run_backend_fast_tests: true
      backend_fast_suite: fast
      backend_ci_command: ./ops/ci-cd/scripts/run-backend-ci.sh
      build_release_command: ./ops/ci-cd/build-release.sh
      release_install_command: ./ops/ci-cd/deploy/release-install.sh
      dry_run_target_root: .artifacts/deploy-target
      telegram_chat_id: ${{ vars.TELEGRAM_CHAT_ID }}
      telegram_notify_on: failure
    secrets:
      telegram_bot_token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
```
