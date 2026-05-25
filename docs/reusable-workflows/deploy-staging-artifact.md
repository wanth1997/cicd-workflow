# `deploy-staging-artifact.yml`

> Status: active reusable workflow for runner-local staging proof
>
> Last updated: 2026-05-25

Reusable staging proof workflow for downloading an existing successful Release
Candidate artifact and installing it into an ephemeral GitHub runner target.

The workflow has no built-in secrets, no SSH, no remote server access, and no
production behavior. Optional Telegram notifications use a caller-provided
`telegram_bot_token` secret.

## Jobs

| Job | Purpose |
|---|---|
| `deploy-staging` | Resolve a Release Candidate run, download its artifact, install it locally, verify manifest / audit shape, write `staging-proof.json`, and upload `staging-deploy-<release_run_id>`. |

## Inputs

| Input | Required | Default |
|---|---:|---|
| `service_name` | yes | |
| `python_version` | yes | |
| `release_run_id` | no | latest successful release workflow run |
| `release_workflow_name` | no | `Release Candidate` |
| `release_branch` | no | `master` |
| `release_artifact_pattern` | yes | |
| `release_install_command` | yes | |
| `runner_target_root` | no | `.artifacts/staging-target` |
| `staging_base_url` | no | empty |
| `tenant_hosts` | no | empty |
| `staging_smoke_command` | no | empty |
| `staging_proof_artifact_prefix` | no | `staging-deploy-` |
| `artifact_retention_days` | no | `14` |
| `telegram_chat_id` | no | empty, disables Telegram |
| `telegram_notify_on` | no | `failure` |

## Secrets

| Secret | Required | Purpose |
|---|---:|---|
| `telegram_bot_token` | no | Service repo Telegram bot token used only when `telegram_chat_id` is set. |

## Telegram Notifications

When enabled, the final `notify-telegram` job sends one concise status message
with repo, stage, workflow, status, branch, commit title plus short SHA, job
result, related Release Candidate run URL, action guidance, and the current
GitHub Run URL. `telegram_notify_on` accepts `failure`, `always`, or `never`.

## Output Artifacts

- `staging-deploy-<release_run_id>`

The artifact contains:

- `staging-proof.json`
- `release-manifest.json`
- `deploy-audit.json`

## Wrapper Example

```yaml
jobs:
  deploy-staging-runner-local:
    if: ${{ inputs.deploy_target == 'runner-local' }}
    uses: wanth1997/cicd-workflow/.github/workflows/deploy-staging-artifact.yml@v0.3.0
    with:
      service_name: ppclub
      python_version: "3.11"
      release_run_id: ${{ inputs.release_run_id }}
      release_workflow_name: Release Candidate
      release_branch: master
      release_artifact_pattern: ppclub-release-*
      release_install_command: ./ops/ci-cd/deploy/release-install.sh
      runner_target_root: .artifacts/staging-target
      staging_base_url: ${{ inputs.staging_base_url }}
      tenant_hosts: ${{ inputs.tenant_hosts }}
      staging_smoke_command: ./ops/ci-cd/deploy/staging-smoke.sh
      staging_proof_artifact_prefix: staging-deploy-
      telegram_chat_id: ${{ vars.TELEGRAM_CHAT_ID }}
      telegram_notify_on: failure
    secrets:
      telegram_bot_token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
```

Remote SSH staging remains service-owned until a real staging host is proven.
