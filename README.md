# cicd-workflow

Reusable GitHub Actions workflows and public-safe CI/CD documentation for
services owned by `wanth1997`.

This repository is public. It must contain only reusable workflow logic,
templates, examples, and documentation. Service secrets and runtime
configuration stay in each service repository's GitHub Environments or on the
target server.

## Current Scope

- `pr-ci-node-python.yml`: reusable PR CI workflow for a Python backend plus
  Node frontend service.
- `pr-ci-go-node.yml`: reusable PR CI workflow for a Go backend plus Node
  frontend service.
- `release-candidate-node-python.yml`: reusable release artifact build workflow
  for Python backend test shards plus Node frontend checks.
- `release-candidate-go-node.yml`: reusable release artifact build workflow for
  Go backend test shards plus Node frontend checks.
- `deploy-dry-run-artifact.yml`: reusable runner-local artifact install
  rehearsal with no remote server access.
- `deploy-staging-artifact.yml`: reusable runner-local staging proof from an
  existing Release Candidate artifact, with no SSH or production access.
- `production-preflight-artifact.yml`: reusable runner-local production
  preflight for verifying a release artifact against staging proof before a
  real production deploy.
- `ci.yml`: this public repository's own static CI for workflow YAML parsing,
  public safety scanning, and Markdown relative link checks.
- Service onboarding cookbook for applying the same CI/CD pattern to future
  services after the Linkcourt / PP Club rollout.
- Public service contract docs for future reusable workflow extraction.
- Public safety policy for secrets and environment data.

## Non-Goals

- No production secrets.
- No `.env` files.
- No SSH private keys.
- No database URLs.
- No production or staging logs.
- No customer data.
- No service-specific production deploy implementation until the consuming
  service has proven that path.

## Read Order

1. [`docs/public-repo-policy.md`](./docs/public-repo-policy.md)
2. [`docs/service-contract.md`](./docs/service-contract.md)
3. [`docs/service-onboarding-cookbook.md`](./docs/service-onboarding-cookbook.md)
4. [`docs/reusable-workflows/pr-ci-node-python.md`](./docs/reusable-workflows/pr-ci-node-python.md)
5. [`docs/reusable-workflows/pr-ci-go-node.md`](./docs/reusable-workflows/pr-ci-go-node.md)
6. [`docs/reusable-workflows/release-candidate-node-python.md`](./docs/reusable-workflows/release-candidate-node-python.md)
7. [`docs/reusable-workflows/release-candidate-go-node.md`](./docs/reusable-workflows/release-candidate-go-node.md)
8. [`docs/reusable-workflows/deploy-dry-run-artifact.md`](./docs/reusable-workflows/deploy-dry-run-artifact.md)
9. [`docs/reusable-workflows/deploy-staging-artifact.md`](./docs/reusable-workflows/deploy-staging-artifact.md)
10. [`docs/reusable-workflows/production-preflight-artifact.md`](./docs/reusable-workflows/production-preflight-artifact.md)
11. [`examples/pr-ci-wrapper.yml`](./examples/pr-ci-wrapper.yml)

## Versioning

Consuming services should pin reusable workflows by tag:

```yaml
uses: wanth1997/cicd-workflow/.github/workflows/pr-ci-node-python.yml@v0.5.0
```

Do not consume workflows from a moving `main` branch.
