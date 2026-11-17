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
  with optional Python backend test shards plus Node frontend checks.
- `release-candidate-go-node.yml`: reusable release artifact build workflow for
  optional Go backend test shards plus Node frontend checks.
- `deploy-dry-run-artifact.yml`: reusable runner-local artifact install
  rehearsal with no remote server access.
- `deploy-staging-artifact.yml`: reusable runner-local staging proof from an
  existing Release Candidate artifact, with no SSH or production access.
- `production-preflight-artifact.yml`: reusable runner-local production
  preflight for verifying a release artifact against staging proof before a
  real production deploy.
- `.github/actions/pool-pick`: composite action that picks a self-hosted pool
  host or GitHub-hosted for a run's jobs ([below](#pool-actions)).
- `.github/actions/pool-evidence`: composite action that prints one memory
  evidence line at the end of a pool job ([below](#pool-actions)).
- `ci.yml`: this public repository's own static CI for workflow and action
  YAML parsing, the pool action tests, public safety scanning, and Markdown
  relative link checks.
- Service onboarding cookbook for applying the same CI/CD pattern to future
  services after the Linkcourt / PP Club rollout.
- Public service contract docs for future reusable workflow extraction.
- Public safety policy for secrets and environment data.

## Optional Telegram Notifications

Reusable workflows can send a final Telegram status message when the consuming
service passes `telegram_chat_id` and the optional `telegram_bot_token` secret.
Messages include repo, stage, workflow, status, branch, commit title, job
results, action guidance, and direct GitHub Run URLs. Tokens and chat IDs stay
in the consuming service repository.

## Pool Actions

A pool is a set of self-hosted hosts (`pc`, `srv`, `srv2`, ...) whose
runners carry exactly one label, `pool-<host>-<class>`, with class `heavy` or
`light`. Each host publishes its status every 30 seconds as a JSON document
(status format version 1) in a repository variable `POOL_STATUS_<HOST>` of a
private status repository. Callers pin both actions by a 40-character commit
SHA.

### `pool-pick`

Run it in a job on a GitHub-hosted runner, so it also runs when the pool is
offline; the other jobs read its outputs with `fromJSON`:

```yaml
jobs:
  pick:
    runs-on: ubuntu-latest
    outputs:
      runs_on_heavy: ${{ steps.pick.outputs.runs_on_heavy }}
      runs_on_light: ${{ steps.pick.outputs.runs_on_light }}
    steps:
      - id: pick
        uses: example-org/cicd-workflow/.github/actions/pool-pick@<40-char SHA>
        with:
          mode: ${{ vars.POOL_RUNNER }}
          token: ${{ secrets.POOL_PICK_TOKEN }}
          status-repo: example-org/pool-status
          runner-group-id: "42"
  build:
    needs: pick
    runs-on: ${{ fromJSON(needs.pick.outputs.runs_on_heavy) }}
```

Rules, in order:

1. Untrusted runs are GitHub-hosted, whatever the mode, with no lookup: a
   `pull_request*` run whose head repository is not this repository (or is
   unknown), an actor or triggering actor `dependabot[bot]`, the events
   `pull_request_target` and `workflow_run`, a public repository, and a
   repository whose visibility is unknown.
2. Mode `github`: GitHub-hosted, no lookup. A mode it does not know fails
   the step.
3. A status it cannot read sends the run to GitHub-hosted, fixed modes too:
   an empty token, a failed request or a non-2xx answer, JSON it cannot read,
   a `v` other than 1, a field it uses with the wrong type. Fields it does
   not know are ignored. `auto` and `pool` read every host in `hosts`; a
   fixed host mode reads only that host.
4. Production labels: a runner in this repository's runner list, or in the
   runner group `runner-group-id` of the repository's organization, with a
   `pool-*` label and a label containing `prod` (any case) sends the run to
   GitHub-hosted. So does a runner list it cannot read in full (up to 5
   pages of 100). Both lists are always checked: when `runner-group-id` is
   missing, empty or not a positive integer, the run is GitHub-hosted (the
   reason says so) and nothing is looked up. Untrusted runs and mode
   `github` do not need it.
5. Candidates: the variable's `updated_at` is at most 120 seconds older than
   the API response's `Date` (GitHub's clock, not the host's), `state` is
   `accepting`, `repos` lists this repository (any case), and every class in
   `classes` has at least one slot.
6. `auto`: the candidate with the most free slots (`slots − busy − queued`)
   of the main class (`heavy` when `classes` has it, else `light`); a tie
   goes to `prefer`, then to the order of `hosts`. When every candidate is
   full the run queues on the one with the fewest waiting jobs; with
   `max-backlog: N` it goes to GitHub-hosted instead once more than N jobs,
   this run included, would wait there. No candidate: GitHub-hosted, and the
   warning names each host's reason (offline and for how long, paused, held,
   draining, repo not in repos, no slot of a class).
7. Fixed modes. A host id: that host even when it is offline, paused, held
   or draining (the jobs wait; a warning says so), as long as its status is
   readable, it lists this repository and it has a slot of every class;
   otherwise GitHub-hosted. `pool`: like `auto` among the accepting hosts but
   always queues (`max-backlog` is ignored); when no host is accepting it
   waits on `prefer`, or on the first host that lists the repository.

The pick is only made when the pick job starts: "Re-run failed jobs" keeps
it, "Re-run all jobs" picks again.

| input | default | meaning |
|---|---|---|
| `mode` | `auto` when empty | `auto`, `pool`, `github`, or a host id from `hosts` |
| `token` | empty | read-only token (below); empty means GitHub-hosted |
| `status-repo` | none, required unless `mode` is `github` | `owner/name` of the status repository |
| `hosts` | `pc,srv` | host ids to read, `POOL_STATUS_<HOST>` each |
| `classes` | `heavy,light` | classes the workflow uses |
| `github-heavy`, `github-light` | `ubuntu-latest` | GitHub-hosted `runs-on`: a label or a JSON array of labels |
| `prefer` | `srv`, or the first of `hosts` without `srv` | wins ties; `pool` waits on it when no host is accepting |
| `max-backlog` | empty: always queue | GitHub-hosted when more than N jobs would wait |
| `runner-group-id` | none, required for a pool pick | the repository's runner group id in its organization (a positive integer); missing or invalid means GitHub-hosted |
| `pr-head-repo` | `github.event.pull_request.head.repo.full_name` | head repository of a pull request |
| `repository-visibility` | `github.event.repository.visibility` | `private` and `internal` are trusted |

| output | meaning |
|---|---|
| `runner` | `pc`, `srv`, ... or `github` |
| `runs_on_heavy`, `runs_on_light` | JSON for `runs-on`: `"pool-<host>-<class>"`, or the GitHub-hosted value |
| `reason` | one line: why |

The step writes the pick line `pool-pick: <mode> picks <runner>: <reason>`
whole into a notice (a warning for a fallback or a host that is not ready)
and into the job summary; reports read it from the annotation. One
`pool-pick detail:` log line per host shows its state, status age and slots.

The token needs read access to the status repository's Actions variables,
Administration read on the repository (its runner list), and the
organization's Self-hosted runners read (the runner group's runners). It
reaches `curl` only on stdin (`--header @-`); it is never in the arguments,
the log or the outputs, and the responses and their headers are not printed.

### `pool-evidence`

Put it last in every pool job with `if: always()`:

```yaml
      - if: always()
        uses: example-org/cicd-workflow/.github/actions/pool-evidence@<40-char SHA>
```

It prints one line from the memory cgroup the step runs in (the job's
container on a pool runner), as a notice (a warning when `oom_kill` is above
0) and in the job summary, and never fails the job:

```text
pool-evidence: runner=pool-pc-heavy-example-app-1234 pool=yes cgroup=v2 peak_mb=2600 limit_mb=4096 failcnt=12 oom_kill=0
```

| output | cgroup v2 | cgroup v1 |
|---|---|---|
| `peak_mb` | `memory.peak` | `memory.max_usage_in_bytes` |
| `limit_mb` | `memory.max` (`max` for none) | `memory.limit_in_bytes` |
| `failcnt` | `memory.events` `max` | `memory.failcnt` |
| `oom_kill` | `memory.events` `oom_kill` | `memory.oom_control` `oom_kill` |

A value it cannot read is `n/a`. Every value is `n/a` when the step's
membership in `/proc/self/cgroup` cannot be mapped under the cgroup mount:
only a membership of exactly `/` (a cgroup namespace, as in a container) reads
the mount root; a path with `..`, or one that is not visible, never falls back
to the root's figures.

### Tests and fixtures

```bash
bash .github/actions/pool-pick/test.sh
bash .github/actions/pool-evidence/test.sh
```

`pool-pick`'s test serves fixture responses through a stand-in `curl`; it
makes no network request. `.github/actions/pool-pick/fixtures/status-*.json`
are copies of the status format's own examples, from the private pool
repository at commit `7a09a332f27924b3f1000329a8580c571d56f1b7` (`tests/fixtures/pool/status-*.json`), with
the repository names and the host name replaced by fake values
(`example-app`, `pool-canary`, `example-host`). Copy them again from the
source at each release that follows a format change, and record the new SHA
here.

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
uses: wanth1997/cicd-workflow/.github/workflows/pr-ci-node-python.yml@v0.9.0
```

Do not consume workflows from a moving `main` branch.
