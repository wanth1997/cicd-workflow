# `deploy-dry-run-artifact.yml`

> Status: draft reusable workflow
>
> Last updated: 2026-05-25

Reusable deploy dry-run workflow for building a release artifact and installing
it into an ephemeral GitHub runner target.

The workflow has no built-in secrets, no remote server access, and no
production behavior. Optional Telegram notifications use a caller-provided
`telegram_bot_token` secret.

## Jobs

| Job | Purpose |
|---|---|
| `deploy-dry-run` | Optionally run fast backend tests, build a release artifact, install it locally, verify manifest / audit shape, and upload dry-run artifacts. |

## Telegram Notifications

When enabled, the final `notify-telegram` job sends one concise status message
with repo, stage, workflow, status, branch, commit title plus short SHA, release
id when available, job result, action guidance, and the GitHub Run URL.
Set `telegram_chat_id` from a service repo variable and pass
`telegram_bot_token` from a service repo secret. `telegram_notify_on` accepts
`failure`, `always`, or `never`.

## Wrapper Example

```yaml
jobs:
  deploy-dry-run:
    uses: wanth1997/cicd-workflow/.github/workflows/deploy-dry-run-artifact.yml@v0.2.0
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
