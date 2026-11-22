# cicd-workflow

<!--
本檔上限 12,000 bytes：每個 session 都全文載入。
新規則全文寫進 docs/ 對應文件，本檔只加一行入口並在「文件索引」加一列。
設計決策記在 docs/project-brief.md 的「## 重要決策」。
-->

## 專案是什麼

Public repository hosting reusable GitHub Actions workflows (`.github/workflows/*.yml`), runner-pool composite actions (`.github/actions/pool-pick`, `.github/actions/pool-evidence`), and public-safe CI/CD onboarding documentation.

## 架構速覽

- `.github/workflows/`: 7 reusable `workflow_call` workflows (`pr-ci-node-python.yml`, `pr-ci-go-node.yml`, `release-candidate-node-python.yml`, `release-candidate-go-node.yml`, `deploy-dry-run-artifact.yml`, `deploy-staging-artifact.yml`, `production-preflight-artifact.yml`) plus `ci.yml` (this repo's own static CI).
- `.github/actions/pool-pick/` & `pool-evidence/`: stdlib Python composite actions + `test.sh` offline fixture suites; callers pin by 40-char commit SHA.
- `docs/` & `examples/`: public safety policy, service contract, onboarding cookbook, per-workflow reference docs, and caller wrapper examples.

## 驗證命令

```bash
ruby -ryaml -e 'Dir[".github/workflows/*.yml", ".github/actions/*/action.yml"].sort.each { |f| YAML.load_file(f) }'
shellcheck .github/actions/*/test.sh
bash .github/actions/pool-pick/test.sh
bash .github/actions/pool-evidence/test.sh
```

## 專案特有規則與禁忌

- **Public repo boundary**: Never commit secrets, `.env` files, SSH keys, real DB/webhook URLs, private hostnames/IPs, staging/prod logs, or customer data -> [public-repo-policy.md](docs/public-repo-policy.md). `ci.yml` enforces secret/path scanning and relative Markdown link resolution on every PR.
- Keep reusable workflow changes backward-compatible via safe input defaults; update the matching `docs/reusable-workflows/<name>.md` when inputs, outputs, or artifacts change.
- `.github/actions/pool-pick/fixtures/status-*.json` must use sanitized fake names (`example-app`, `pool-canary`, `example-host`).

## 文件索引

| 什麼時候讀 | 文件 | 涵蓋 |
|---|---|---|
| 新增或修改任何檔案前 | [public-repo-policy.md](docs/public-repo-policy.md) | Public 安全紅線與發 PR 前掃描清單 |
| 修改 `.github/actions/pool-*` 前 | [README.md](README.md) | `pool-pick` 決策順序、inputs/outputs、`pool-evidence` cgroup 規則與 fixture 來源 |
| 修改 reusable workflows 前 | [service-contract.md](docs/service-contract.md)、[service-onboarding-cookbook.md](docs/service-onboarding-cookbook.md) | Caller 與 reusable workflow 職責切分、script 與 manifest 契約 |

## 相關文件

- [docs/project-brief.md](docs/project-brief.md)（架構與重要決策）、[docs/work-log.md](docs/work-log.md)
