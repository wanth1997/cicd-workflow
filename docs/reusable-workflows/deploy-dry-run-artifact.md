# `deploy-dry-run-artifact.yml`

> Status: draft reusable workflow
>
> Last updated: 2026-05-22

Reusable deploy dry-run workflow for building a release artifact and installing
it into an ephemeral GitHub runner target.

The workflow has no secrets, no remote server access, and no production
behavior.

## Jobs

| Job | Purpose |
|---|---|
| `deploy-dry-run` | Optionally run fast backend tests, build a release artifact, install it locally, verify manifest / audit shape, and upload dry-run artifacts. |

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
```
