# `pr-ci-go-node.yml`

> Status: draft reusable workflow
>
> Last updated: 2026-11-15

Reusable PR CI workflow for a service with:

- Go backend
- Node frontend
- ephemeral PostgreSQL migration check
- service-owned test scripts
- optional full backend test shards for PR merge gates

The workflow has no built-in secrets and no deploy behavior. Optional Telegram
notifications use a caller-provided `telegram_bot_token` secret.

## Jobs

| Job | Purpose |
|---|---|
| `backend-fast-tests` | Run the service's fast Go backend test suite. |
| `backend-migration-tests` | Run migration regression tests. |
| `backend-full-tests` | Optionally run full Go backend test shards from `backend_full_shards_json`. |
| `backend-migration` | Run fresh PostgreSQL migration and schema check. |
| `frontend-checks` | Run frontend install / lint / tests / build through a service-owned script. |

## Inputs

| Input | Required | Default |
|---|---:|---|
| `service_name` | yes | |
| `go_version_file` | yes | |
| `go_dependency_file` | yes | |
| `node_version` | yes | |
| `frontend_dir` | yes | |
| `frontend_lockfile` | yes | |
| `backend_fast_suite` | yes | |
| `backend_migration_suite` | yes | |
| `run_backend_full_tests` | no | `false` |
| `backend_full_shards_json` | no | `[]` |
| `backend_ci_command` | yes | |
| `migration_check_command` | yes | |
| `frontend_ci_command` | yes | |
| `postgres_image` | no | `postgres:15` |
| `postgres_db` | no | `app_ci` |
| `postgres_user` | no | `app` |
| `postgres_password` | no | `app` |
| `artifact_retention_days` | no | `14` |
| `telegram_chat_id` | no | empty, disables Telegram |
| `telegram_notify_on` | no | `failure` |
| `runner` | no | `ubuntu-latest` (one label, or a JSON label array such as `["self-hosted","Linux","X64","wsl"]`) |
| `go_flags` | no | empty (`GOFLAGS` of the Go jobs, e.g. `-p=4`) |
| `postgres_service_options` | no | `--memory=768m --cpus=2` |

## Secrets

| Secret | Required | Purpose |
|---|---:|---|
| `telegram_bot_token` | no | Service repo Telegram bot token used only when `telegram_chat_id` is set. |

## Telegram Notifications

When enabled, the final `notify-telegram` job sends one concise status message
with repo, stage, workflow, status, branch, commit title plus short SHA, job
results, action guidance, and the GitHub Run URL. `telegram_notify_on` accepts
`failure`, `always`, or `never`.

## Runners

`runner` sets `runs-on` for `backend-fast-tests`, `backend-migration-tests`,
`backend-full-tests`, `backend-migration` and `frontend-checks`. A value that
starts with `[` is read as a JSON array of labels; anything else is one label.
`notify-telegram` always runs on `ubuntu-latest`, so a failure is still
reported when a self-hosted machine is down.

The workflow does not pick or check the runner itself. A caller that wants a
self-hosted runner with a fallback to GitHub-hosted resolves it in its own
job first (for example from the repository's runner list) and passes the
result here. A self-hosted label set must include a label that no deploy or
production runner carries, so a PR job can never land on one.

What changes on a self-hosted runner (`runner.environment == 'self-hosted'`):

- Each job first sets `HOME` to `$RUNNER_TEMP/home`. The runner user and its
  `$HOME` are shared by every job and repository on the machine; with a
  per-job `HOME`, the Go module and build caches, the npm cache, `go env -w`
  and any global git config live in `_temp`, which the runner empties for
  each job, and nothing from another job's `~/.gitconfig` is read.
  `actions/setup-go` and `actions/setup-node` resolve their cache paths
  (`go env GOMODCACHE`/`GOCACHE`, `npm config get cache`) under that `HOME`
  on both restore and save. The cache version includes those absolute
  paths, so each runner keeps its own cache entries; after its first run a
  runner hits its own cache. GitHub-hosted jobs skip this step.
- `actions/checkout` runs with `persist-credentials: false`, so no token is
  left in the workspace `.git/config` or in `_temp`. The service commands
  must not need authenticated git.

On every runner:

- The PostgreSQL service publishes 5432 on a host port Docker picks (jobs on
  one machine never collide), and a step exports `DATABASE_URL` and
  `TEST_DATABASE_URL` with that port to `GITHUB_ENV`. The migration command
  must read them rather than assume `localhost:5432`.
- `postgres_service_options` is appended to the service container's docker
  options. Service containers run outside the runner's own resource limits
  (for example a systemd slice), so the default caps them at
  `--memory=768m --cpus=2`.
- `go_flags` becomes `GOFLAGS` of the four Go jobs. On a machine with many
  CPUs shared with other runners, `-p=4` bounds how many packages build and
  test at once; flags given on a command line still win.

## Version Notes

- `v0.9.0`: adds `runner`, `go_flags` and `postgres_service_options`; the
  per-job `HOME` on self-hosted runners; `persist-credentials: false` on
  checkout; and the PostgreSQL service on a Docker-picked host port, with
  `DATABASE_URL`/`TEST_DATABASE_URL` exported from it (was a fixed
  `5432:5432` with the URLs in the job env). With the defaults, the jobs run
  on `ubuntu-latest` as before.

## Output Artifacts

- `<service_name>-backend-fast-go-test-report`
- `<service_name>-backend-migration-go-test-report`
- `<service_name>-backend-full-<shard>-go-test-report` when `run_backend_full_tests` is true

The service-owned backend command should write Go test JSON to the
`GO_TEST_JSON` path provided by the workflow.

For a protected default branch, PR CI should own the full merge gate: set
`run_backend_full_tests: true` and provide `backend_full_shards_json` in the
service wrapper. Main-branch push workflows can then skip repeated backend full
test shards and focus on release artifact checks.
