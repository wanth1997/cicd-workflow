# cicd-workflow

## 目標

提供公開、可重用的 GitHub Actions workflows 與 runner-pool composite actions，讓各服務倉庫只維護自己的業務腳本、環境設定與部署審核，把 checkout、runtime setup、cache、artifact、summary 與安全預設值等共用 CI/CD 機制集中在此維護。

## 架構 / 技術棧

- `.github/workflows/`: 7 支 active `workflow_call` reusable workflows（Python+Node 與 Go+Node 的 PR CI / Release Candidate，以及 runner-local Deploy Dry Run、Deploy Staging、Production Preflight）與本 repo 自身的靜態檢查 `ci.yml`。
- `.github/actions/pool-pick/` 與 `.github/actions/pool-evidence/`: 僅依賴 Python 標準函式庫的 composite actions，搭配離線 fixture 測試腳本 `test.sh` 與 `shellcheck`。
- `docs/` 與 `examples/`: 公開安全政策、服務契約、導入 cookbook、各 workflow 規格與 caller wrapper 範例。

## 目前狀態

目前最新穩定版本為 `v0.11.1`。7 支 reusable workflows 與兩支 runner-pool composite actions（含 `pool-pick` 的 `fill` 模式與 `pool-evidence` 的 cgroup v1 `mountinfo` 支援）皆為 active，並由 `ci.yml` 在每次 PR 執行 YAML 解析、pool action 測試、公開安全邊界掃描與 Markdown 相對連結檢查。

## 重要決策

- **永久 public 安全邊界**：嚴禁提交任何 secret、`.env`、SSH 私鑰、真實資料庫／webhook URL、內網主機名／IP、staging/prod 日誌或客戶資料（詳見 `docs/public-repo-policy.md`）。
- **Caller 版本釘選**：消耗端服務呼叫 reusable workflows 一律釘選 release tag（例如 `@v0.11.1`）；呼叫 `pool-pick` / `pool-evidence` composite actions 一律釘選 40 字元 commit SHA，不使用浮動 `main`。
- **向後相容與職責切分**：新增 workflow inputs 優先提供安全預設值；遠端 SSH staging 與真實 production deploy 留在各服務倉庫，直到多服務驗證完畢。
- **Fixture 去敏化**：`.github/actions/pool-pick/fixtures/status-*.json` 一律使用假名稱（`example-app`、`pool-canary`、`example-host`）。

## 待辦 / 下一步

- 持續維護 reusable workflows 與 pool actions 的向後相容更新，變更 inputs/outputs 時同步更新 `docs/reusable-workflows/*.md` 與 `README.md`。
- 依 `docs/service-onboarding-cookbook.md` 協助新服務導入，僅在跨服務共同需求成熟時抽取新的共用 workflow。
