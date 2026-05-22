# `production-preflight-artifact.yml`

> Status: active reusable workflow for runner-local production preflight
>
> Last updated: 2026-05-23

Reusable production preflight workflow for proving that a successful Release
Candidate artifact matches a staging proof and can be installed on a GitHub
runner before a real production deploy.

This workflow does not SSH to a server, run migrations, restart services, or
deploy to production.

## Jobs

| Job | Purpose |
|---|---|
| `production-preflight` | Resolve Release Candidate and Deploy Staging runs, verify matching artifacts, install the release into a runner-local target, optionally run a confirmed read-only health check, and upload `production-preflight-<release_run_id>`. |

## Inputs

| Input | Required | Default |
|---|---:|---|
| `service_name` | yes | n/a |
| `python_version` | yes | n/a |
| `release_run_id` | no | empty, resolves latest successful release branch run |
| `staging_run_id` | no | empty, resolves latest successful staging run with matching proof |
| `release_workflow_name` | no | `Release Candidate` |
| `staging_workflow_name` | no | `Deploy Staging` |
| `release_branch` | no | `master` |
| `release_artifact_pattern` | yes | n/a |
| `staging_proof_artifact_prefix` | no | `staging-deploy-` |
| `preflight_artifact_prefix` | no | `production-preflight-` |
| `release_install_command` | yes | n/a |
| `runner_target_root` | no | `.artifacts/production-preflight-target` |
| `require_remote_staging` | no | `false` |
| `production_base_url` | no | empty |
| `confirm_production_health_check` | no | empty |
| `health_check_command` | no | empty |
| `artifact_retention_days` | no | `14` |

## Outputs

This workflow uploads:

- `production-preflight-<release_run_id>`

The artifact contains:

- preflight target `release-manifest.json`
- preflight target `deploy-audit.json`
- selected staging `staging-proof.json`
- selected staging `deploy-audit.json`

## Safety

- No SSH.
- No migrations.
- No service restart.
- No remote deploy.
- No production URL call unless `production_base_url` is non-empty and
  `confirm_production_health_check` is exactly `CALL_PRODUCTION_HEALTH`.
- Production environment approvals should stay in the consuming service
  wrapper before calling this reusable workflow.

## Example Caller

```yaml
jobs:
  production-gate:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - run: echo "Production environment gate passed."

  production-preflight:
    needs: production-gate
    uses: wanth1997/cicd-workflow/.github/workflows/production-preflight-artifact.yml@v0.4.0
    with:
      service_name: ppclub
      python_version: "3.11"
      release_run_id: ${{ inputs.release_run_id }}
      staging_run_id: ${{ inputs.staging_run_id }}
      release_workflow_name: Release Candidate
      staging_workflow_name: Deploy Staging
      release_branch: master
      release_artifact_pattern: ppclub-release-*
      staging_proof_artifact_prefix: staging-deploy-
      preflight_artifact_prefix: production-preflight-
      release_install_command: ./ops/ci-cd/deploy/release-install.sh
      runner_target_root: .artifacts/production-preflight-target
      require_remote_staging: ${{ inputs.require_remote_staging }}
      production_base_url: ${{ inputs.production_base_url }}
      confirm_production_health_check: ${{ inputs.confirm_production_health_check }}
      health_check_command: ./ops/ci-cd/deploy/health-check.sh
      artifact_retention_days: 14
```
