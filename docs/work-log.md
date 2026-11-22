# 工作記錄

<!--
新記錄追加在本註解下方（最新的在最前面）。每筆格式：

## YYYY-MM-DD HH:MM — 簡短標題

**改動摘要：** 一句話描述做了什麼

**修改的檔案：**
- `path/to/file` — 改了什麼

**原因/備註：** （選填，補充說明）

---
-->

## 2026-11-22 18:55 — 建立 agent 文件並同步 reusable workflow 契約與範例

**改動摘要：** 新增公開安全邊界內的 `AGENTS.md`、`CLAUDE.md`、`docs/project-brief.md` 與 `docs/work-log.md`，`.gitignore` 補列 `.DS_Store`，同步所有 reusable workflow 文件狀態為 `active`、補齊缺少的 Inputs/Artifacts 表、統一範例 tag 至 `@v0.11.1`，並精簡 `docs/service-onboarding-cookbook.md` 的重複 YAML 與補齊 Go 規格。

**修改的檔案：**
- `.gitignore` — 加入 `.DS_Store`
- `AGENTS.md`、`CLAUDE.md` — 新增專案入口文件與單行 `@AGENTS.md` 匯入
- `docs/project-brief.md`、`docs/work-log.md` — 新增專案簡報與工作記錄
- `README.md`、`examples/pr-ci-wrapper.yml` — 統一範例 tag 為 `@v0.11.1`
- `docs/service-contract.md` — 狀態改為 `active contract`，依 workflow family 拆分 common inputs 並補齊 `pool-pick`/`pool-evidence` 索引
- `docs/reusable-workflows/*.md` — 狀態統一為 `active reusable workflow`，補齊 `release-candidate-{go-node,node-python}.md` 與 `deploy-dry-run-artifact.md` 的 Inputs／Secrets／Output Artifacts 表，統一範例 tag 至 `@v0.11.1`
- `docs/service-onboarding-cookbook.md` — 補齊 Go 服務欄位（`GO_TEST_JSON`、`go_version_file`、`go_dependency_file`），將重複的 5 段完整 caller YAML 改為索引表

**原因/備註：** 嚴格遵守 `docs/public-repo-policy.md`，所有新增與修改內容均不含 secret、內網主機／IP 或本機路徑。
