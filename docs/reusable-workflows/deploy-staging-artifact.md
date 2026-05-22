# `deploy-staging-artifact.yml`

> Status: active reusable workflow for runner-local staging proof
>
> Last updated: 2026-05-22

Reusable staging proof workflow for downloading an existing successful Release
Candidate artifact and installing it into an ephemeral GitHub runner target.

The workflow has no secrets, no SSH, no remote server access, and no
production behavior.

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
```

Remote SSH staging remains service-owned until a real staging host is proven.
