# Service CI/CD Onboarding Cookbook

> Status: onboarding guide
>
> Last updated: 2026-05-25
>
> Reference rollouts: Linkcourt, also known as PP Club; ZenIncome

這份 cookbook 說明新的 service 要如何套用本 repo 的 reusable GitHub
Actions workflow。目標是讓每個 service 只維護自己的業務腳本與環境設定，
把 checkout、runtime setup、cache、artifact、summary、安全預設值等 CI/CD
機械工作交給共用 workflow。

## 上線完成定義

一個新 service 完成 onboarding，至少要達成這些條件：

1. PR CI 在 branch 上跑綠，且 branch protection 已改成新的實際 check
   names。
2. Release Candidate workflow 可以從 default branch 產出 release artifact。
3. Deploy Dry Run 可以把 release artifact 安裝到 GitHub runner-local target。
4. Deploy Staging 可以針對指定 Release Candidate 產出 `staging-proof.json`。
5. Production Preflight 可以驗證 Release Candidate artifact 與 staging proof
   相符。
6. Production deploy 邏輯仍留在 service repo，直到該 service 已證明 staging、
   rollback、production approval 行為都可靠。

## 核心守則

- Reusable workflow 只負責共用 CI/CD mechanics；service repo 負責測試、建置、
  migration、health check、部署腳本與環境設定。
- 選擇符合 runtime family 的 reusable workflow：Python backend 用
  `*-node-python.yml`，Go backend 用 `*-go-node.yml`。不要為了套用共用流程而把
  service script 寫成偽裝成另一個 runtime。
- 所有 caller workflow 都要 pin 到 tag，例如 `@v0.7.0`。不要用 moving
  `main`。
- 先上無 secret、無遠端副作用的流程：PR CI、Release Candidate、Deploy Dry
  Run、runner-local Deploy Staging、Production Preflight。
- 任何 secret value、`.env`、server inventory、production/staging log 都不能
  放到這個 public repo。service runtime values 要留在 consuming service repo
  的 GitHub Environments 或目標主機。
- 每次搬遷只搬一個 workflow family。先在 branch 上跑綠，再改 branch
  protection。
- 不要預猜 GitHub check names。等 reusable workflow 實際跑完後，記錄 GitHub
  顯示的精確 check names，再更新 branch protection。

## Service 適用性檢查

導入前先填完這張表。若答案不明確，先補 service repo 的腳本或文件，不要急著
接 reusable workflow。

| 項目 | 要確認的事 |
|---|---|
| Service id | 穩定、短、小寫，例如 Linkcourt/PP Club 使用 `ppclub`。artifact prefix 會用到它。 |
| Default branch | `main` 或 `master`。所有 wrapper 的 trigger 與 `release_branch` 要一致。 |
| Runtime | Python backend 與 Node frontend 的版本，例如 Python `3.11`、Node `24`。 |
| Repo layout | backend/frontend 目錄、Python dependency file、NPM lockfile 都要固定。 |
| Backend suites | 至少要能分出 fast、migration regression、full shards。 |
| Migration check | 必須能使用 workflow 提供的 ephemeral `DATABASE_URL`，不能打到真實 DB。 |
| Frontend checks | 必須能用單一 script 完成 install、lint、test、build。 |
| Release artifact | 必須能由 service script 建立可安裝的 release directory。 |
| Install contract | 必須支援 runner-local install，且能遵守 `--skip-migrations`、`--no-restart`。 |
| Staging/production | 初期只證明 runner-local 與 read-only health。SSH deploy 與真實 production deploy 留在 service repo。 |

## Service-Owned Script Contract

Reusable workflow 會呼叫 service repo 裡的 command。這些 command 要從 repo root
執行、可重複執行、失敗時用非 0 exit code、不要印出 secret。

| Command input | Workflow 提供 | Service script 必須做到 |
|---|---|---|
| `backend_ci_command` | `BACKEND_TEST_SUITE`、`PYTEST_JUNIT_XML` | 依 suite 跑 pytest，並把 JUnit XML 寫到 `PYTEST_JUNIT_XML`。 |
| `migration_check_command` | Ephemeral `DATABASE_URL` | 對乾淨 PostgreSQL 跑 migration，並檢查 schema drift。 |
| `frontend_ci_command` | Node runtime 與 npm cache | 安裝 frontend dependencies，跑 lint/test/build。 |
| `build_release_command` | `REQUIRE_CLEAN` | 建立 release directory，並寫入 `$GITHUB_OUTPUT` 的 `release_id` 與 `release_dir`。 |
| `release_install_command` | `--release-dir`、`--target-root`、`--skip-migrations`、`--no-restart` | 安裝 artifact 到 target root，建立 `current` symlink，且在 skip/no-restart flags 存在時不得跑 migration 或重啟服務。 |
| `staging_smoke_command` | `BASE_URL`、`STAGING_TENANT_HOSTS` | 當 wrapper 傳入 staging URL 時，執行 read-only smoke check。 |
| `health_check_command` | Production base URL 作為第一個參數 | 只做 read-only health check；Production Preflight 需要明確 confirmation 才會呼叫。 |

`build_release_command` 產出的 release directory 至少要包含：

- `release-manifest.json`
- backend payload
- frontend build output

`release_install_command` 安裝完成後，target root 至少要符合：

- `<target-root>/current` 是 symlink
- `<target-root>/current/release-manifest.json` 是合法 JSON
- `<target-root>/current/deploy-audit.json` 是合法 JSON
- `<target-root>/current/backend` 存在
- `<target-root>/current/frontend-dist` 存在

`release-manifest.json` 至少要能讓 staging/prod proof 比對：

```json
{
  "release_id": "service-20260525-abcdef0",
  "git_sha": "abcdef0123456789",
  "database": {
    "alembic_head": "0123456789ab"
  }
}
```

## 建議 Wrapper 檔案

每個 service repo 建議保留這五個 caller workflow。以下範例使用 `main`，若
service default branch 是 `master`，要同步改 trigger 與 `release_branch`。

事件分工：

- PR CI 只在 `pull_request` to `main` 執行，並作為完整 merge gate。
- Release Candidate 只在 `push` to `main` 或手動觸發時執行；自動 main push
  不重跑 backend full-test shards，只保留 migration、frontend、artifact build
  這類 release 必要檢查。
- Feature branch push 不建議呼叫 full reusable workflow；若需要，可在 service
  repo 自行加一個快速 lint/format workflow。

Telegram 通知設定：

- 在 service repo 設定 repository variable `TELEGRAM_CHAT_ID`。
- 在 service repo 設定 repository secret `TELEGRAM_BOT_TOKEN`。
- `telegram_notify_on: failure` 只會在非 success 時通知；若要每次都通知，改成
  `always`。

### `.github/workflows/pr-ci.yml`

```yaml
name: PR CI

on:
  pull_request:
    branches:
      - main

permissions:
  contents: read

jobs:
  pr-ci:
    uses: wanth1997/cicd-workflow/.github/workflows/pr-ci-node-python.yml@v0.7.0
    with:
      service_name: example-service
      python_version: "3.11"
      node_version: "24"
      backend_dir: backend
      frontend_dir: frontend
      backend_dependency_file: backend/requirements.txt
      frontend_lockfile: frontend/package-lock.json
      backend_fast_suite: fast
      backend_migration_suite: migration
      run_backend_full_tests: true
      backend_full_shards_json: >
        [
          {"shard":"api","suite":"full-api","report":"backend-full-api-pytest.xml"},
          {"shard":"domain","suite":"full-domain","report":"backend-full-domain-pytest.xml"}
        ]
      backend_ci_command: ./ops/ci-cd/scripts/run-backend-ci.sh
      migration_check_command: ./ops/ci-cd/scripts/run-backend-migration-check.sh
      frontend_ci_command: ./ops/ci-cd/scripts/run-frontend-ci.sh
      telegram_chat_id: ${{ vars.TELEGRAM_CHAT_ID }}
      telegram_notify_on: failure
    secrets:
      telegram_bot_token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
```

### `.github/workflows/release-candidate.yml`

```yaml
name: Release Candidate

on:
  workflow_dispatch:
  push:
    branches:
      - main

permissions:
  contents: read

jobs:
  release-candidate:
    uses: wanth1997/cicd-workflow/.github/workflows/release-candidate-node-python.yml@v0.7.0
    with:
      service_name: example-service
      python_version: "3.11"
      node_version: "24"
      backend_dependency_file: backend/requirements.txt
      frontend_lockfile: frontend/package-lock.json
      run_backend_full_tests: false
      backend_shards_json: >
        [
          {"shard":"api","suite":"full-api","report":"backend-full-api-pytest.xml"},
          {"shard":"domain","suite":"full-domain","report":"backend-full-domain-pytest.xml"}
        ]
      backend_ci_command: ./ops/ci-cd/scripts/run-backend-ci.sh
      migration_check_command: ./ops/ci-cd/scripts/run-backend-migration-check.sh
      frontend_ci_command: ./ops/ci-cd/scripts/run-frontend-ci.sh
      build_release_command: ./ops/ci-cd/build-release.sh
      release_artifact_prefix: example-service-release-
      telegram_chat_id: ${{ vars.TELEGRAM_CHAT_ID }}
      telegram_notify_on: failure
    secrets:
      telegram_bot_token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
```

### `.github/workflows/deploy-dry-run.yml`

```yaml
name: Deploy Dry Run

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  deploy-dry-run:
    uses: wanth1997/cicd-workflow/.github/workflows/deploy-dry-run-artifact.yml@v0.7.0
    with:
      service_name: example-service
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

### `.github/workflows/deploy-staging.yml`

```yaml
name: Deploy Staging

on:
  workflow_dispatch:
    inputs:
      release_run_id:
        description: Successful Release Candidate run id. Empty means latest successful run.
        required: false
        type: string
      staging_base_url:
        description: Optional read-only staging base URL.
        required: false
        type: string
      tenant_hosts:
        description: Optional comma-separated tenant hosts for smoke checks.
        required: false
        type: string

permissions:
  actions: read
  contents: read

jobs:
  deploy-staging-runner-local:
    uses: wanth1997/cicd-workflow/.github/workflows/deploy-staging-artifact.yml@v0.7.0
    with:
      service_name: example-service
      python_version: "3.11"
      release_run_id: ${{ inputs.release_run_id }}
      release_workflow_name: Release Candidate
      release_branch: main
      release_artifact_pattern: example-service-release-*
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

### `.github/workflows/production-preflight.yml`

```yaml
name: Production Preflight

on:
  workflow_dispatch:
    inputs:
      release_run_id:
        description: Successful Release Candidate run id. Empty means latest successful run.
        required: false
        type: string
      staging_run_id:
        description: Successful Deploy Staging run id. Empty means latest matching proof.
        required: false
        type: string
      require_remote_staging:
        description: Require a remote-ssh staging proof before production preflight.
        required: false
        type: boolean
        default: false
      production_base_url:
        description: Optional read-only production health URL.
        required: false
        type: string
      confirm_production_health_check:
        description: Must be CALL_PRODUCTION_HEALTH to call production_base_url.
        required: false
        type: string

permissions:
  actions: read
  contents: read

jobs:
  production-gate:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - run: echo "Production environment gate passed."

  production-preflight:
    needs: production-gate
    uses: wanth1997/cicd-workflow/.github/workflows/production-preflight-artifact.yml@v0.7.0
    with:
      service_name: example-service
      python_version: "3.11"
      release_run_id: ${{ inputs.release_run_id }}
      staging_run_id: ${{ inputs.staging_run_id }}
      release_workflow_name: Release Candidate
      staging_workflow_name: Deploy Staging
      release_branch: main
      release_artifact_pattern: example-service-release-*
      staging_proof_artifact_prefix: staging-deploy-
      preflight_artifact_prefix: production-preflight-
      release_install_command: ./ops/ci-cd/deploy/release-install.sh
      runner_target_root: .artifacts/production-preflight-target
      require_remote_staging: ${{ inputs.require_remote_staging }}
      production_base_url: ${{ inputs.production_base_url }}
      confirm_production_health_check: ${{ inputs.confirm_production_health_check }}
      health_check_command: ./ops/ci-cd/deploy/health-check.sh
      telegram_chat_id: ${{ vars.TELEGRAM_CHAT_ID }}
      telegram_notify_on: failure
    secrets:
      telegram_bot_token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
```

## 推進順序

1. 先在 service repo 新增或整理 `ops/ci-cd/` scripts。所有 script 都要能在本機或
   GitHub runner 上從 repo root 執行。
2. 新增 PR CI wrapper，開一支測試 PR，確認 backend fast、migration tests、
   backend full shards、migration check、frontend checks 都跑綠。
3. 記錄 GitHub 顯示的實際 check names，再更新 branch protection。不要沿用舊
   workflow 的 required checks。
4. 新增 Release Candidate wrapper，從 default branch 跑一次。確認 main push
   沒有重跑 backend full shards，release artifact 名稱符合
   `<service>-release-*`，且 artifact 裡有 manifest。
5. 新增 Deploy Dry Run wrapper，確認 runner-local install 會產生 `current`
   symlink、`release-manifest.json`、`deploy-audit.json`。
6. 新增 Deploy Staging wrapper。第一次建議指定 `release_run_id`，避免抓到不是
   這次測試的 latest successful run。
7. 新增 Production Preflight wrapper，指定同一個 `release_run_id` 與 staging
   proof。先不要傳 `production_base_url`；等 read-only health script 被審過後再
   加。
8. 整理 service README 或 runbook，記下 workflow tag、script contract、artifact
   naming、branch protection check names、人工 approval owner。

## Production Deploy 抽取準則

目前 reusable workflow 不包含真實 production deploy。只有在同一套模式至少被
多個 service 證明後，才考慮把 remote deploy 抽成 reusable workflow。抽取前必須
先具備：

- staging 已能證明同一個 Release Candidate artifact 被部署與 smoke tested。
- rollback script 已在 service repo 被測過，且能回到上一個 release。
- production deploy 有 GitHub Environment approval。
- migration strategy 已被文件化，包含 backward-compatible migration 與失敗處理。
- deploy script 能把 `release_id`、`git_sha`、`alembic_head` 寫進 deploy audit。
- secret、SSH key、server host、runtime env values 全部留在 consuming service
  repo 或 GitHub Environment。

## 升級與維護

- 每個 service 應以獨立 PR 升級 workflow tag，例如 `v0.6.0` 到 `v0.7.0`。
- 升級 PR 要重新跑 PR CI、Release Candidate、Deploy Dry Run。若 staging/preflight
  input contract 有變，也要重跑 Deploy Staging 與 Production Preflight。
- 若新增 input，優先提供 safe default；破壞性變更要發新 tag 並更新各 workflow
  文件。
- 若某個 service 需要特殊行為，先放在 service-owned script。只有當第二個 service
  也需要同一行為時，再評估抽到 reusable workflow。

## 常見失敗與處理

| 現象 | 優先檢查 |
|---|---|
| Deploy Staging 找不到 artifact | Release Candidate run 是否成功、`release_artifact_pattern` 是否符合 artifact name、artifact 是否過期。 |
| Release artifact upload 失敗 | `build_release_command` 是否有寫 `$GITHUB_OUTPUT` 的 `release_id` 與 `release_dir`。 |
| Staging proof 與 release 不符 | `release_run_id`、`staging_run_id` 是否選到同一次 release；manifest 是否被 install script 改寫。 |
| Production health 被拒絕 | `production_base_url` 不為空時，`confirm_production_health_check` 必須精確等於 `CALL_PRODUCTION_HEALTH`，且要提供 `health_check_command`。 |
| Migration check 打到真實 DB | `migration_check_command` 沒有使用 workflow 注入的 ephemeral `DATABASE_URL`。 |
| Branch protection 卡住 | Required check names 還是舊 workflow 名稱，或 reusable workflow 實際 check names 尚未更新。 |
| Pytest report 沒上傳 | Backend script 沒有把 JUnit XML 寫到 `PYTEST_JUNIT_XML`。 |

## Onboarding Ticket Template

```markdown
## Service CI/CD onboarding

- Service id:
- Default branch:
- Python version:
- Node version:
- Backend dir:
- Frontend dir:
- Backend dependency file:
- Frontend lockfile:
- Release artifact prefix:
- Workflow tag:
- PR CI check names:
- Release Candidate run id:
- Deploy Staging run id:
- Production approval owner:

### Required scripts

- [ ] backend_ci_command:
- [ ] migration_check_command:
- [ ] frontend_ci_command:
- [ ] build_release_command:
- [ ] release_install_command:
- [ ] staging_smoke_command:
- [ ] health_check_command:

### Rollout

- [ ] PR CI green on branch
- [ ] Branch protection updated with actual check names
- [ ] Release Candidate artifact created
- [ ] Deploy Dry Run installed artifact runner-locally
- [ ] Deploy Staging produced staging proof
- [ ] Production Preflight matched release and staging proof
- [ ] Service runbook updated
```
