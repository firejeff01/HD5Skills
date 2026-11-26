# HD5Skills — 跟程式技術無關的 AI 協作開發工作流

把「需求 → 設計 → 實作 → 測試 → 驗收」的工作流裝進**任何**程式技術的 repo（新專案或既有專案），Claude Code 與 Codex 都能用。
流程本身不綁技術；每個 repo 的技術細節由 `hd5-onboard` 掃描專案後產生。

> 2026-11-23 起。源自 IMOCore（ASUS GHGP）專案的實戰流程，參考 Lauren Tan〈All Code Is Slop (Except Mine)〉、create-verification-skill
> 與 Matt Pocock 的 skills：skill 只教方法，專案事實留在專案裡。

## 給使用者看的說明（HTML，雙擊即可離線開）

- [docs/導入說明.html](docs/導入說明.html)：白話的導入步驟、日常怎麼用、整體流程、優點、注意事項、常見問題
- [docs/skills地圖.html](docs/skills地圖.html)：12 個 skill 在案子哪個階段出場、誰用、怎麼叫、產出、會擋人的關卡

## 兩步導入

```powershell
# 1. 安裝（repo 要先 git init；ProjectDir＝Claude Code 啟動的資料夾，在 repo 根就不給）
#    在已開的 pwsh 視窗用 & 執行，不要 pwsh -File 另開程序——端點防護（例 COMODO）會把它關進隔離區，裝完檔案卻不在（11-24）
& ./HD5Skills/install.ps1 -RepoRoot D:\work\MyRepo [-ProjectDir src\MyApp]

# 2. 在那個資料夾啟動 Claude Code（或 Codex），說「導入工作流」或執行 /hd5-onboard
```

`hd5-onboard` 會：掃描專案 → 讀懂架構 → 一題一題問你掃描推不出來的事 → 產生
`AGENTS.md`（Claude 與 Codex 共用的主檔）、`CLAUDE.md`（第一行 `@AGENTS.md`，只放 Claude 專屬）、實作代理（含本專案技術架構重點）、
`.claude/workflow.json`、功能地圖骨架 → 用 `check-onboard.mjs` 把關。

## 之後更新套件

已導入過的專案，套件出新版時用 `-Update`：只把套件擁有的檔（`.claude/skills/hd5-*`、`.agents/skills/hd5-*`、`paths.tools` 底下的工具；
工單工具只在 `tracker.type`＝azure-devops 時）覆蓋成新版，**不動** AGENTS.md、CLAUDE.md、`.claude/agents`、`workflow.json`、`settings.json`、
spec／verify／onboard 與 PAT 檔；不刪檔，套件已不含的檔只列出來請你確認。

```powershell
& ./HD5Skills/install.ps1 -RepoRoot D:\work\MyRepo [-ProjectDir src\MyApp] -Update
```

## 技能清單

| 技能 | 用途 |
|---|---|
| [hd5-workflow](hd5-workflow/SKILL.md) | 流程總綱：案件路線（四角色／PM 端已完成／小問題）、角色、關卡、錯誤升級階梯、人工閘門；工具在 `tools/`（裝到專案的 `AI_Service/hd5-tools/`） |
| [hd5-onboard](hd5-onboard/SKILL.md) | 起手：掃描 repo、產生 AGENTS.md／CLAUDE.md／代理／workflow.json／功能地圖骨架 |

| [hd5-grill](hd5-grill/SKILL.md) | 需求／設計質詢輪（決策樹拍板法） |
| [hd5-no-hallucination](hd5-no-hallucination/SKILL.md) | 文件沒定義不腦補，改列問題清單 |
| [hd5-spec-html](hd5-spec-html/SKILL.md) | 需求 HTML 摘要＋Open Questions 互動問卷 |
| [hd5-tdd](hd5-tdd/SKILL.md) | TDD 紅綠燈紀律＋驗紅＋mutation |
| [hd5-verify](hd5-verify/SKILL.md) | 照功能地圖像使用者一樣驗證，回報三態 |
| [hd5-review](hd5-review/SKILL.md) | 獨立驗收（Codex 或全新子代理） |
| [hd5-onsite-gate](hd5-onsite-gate/SKILL.md) | 部署測試環境後的站上關卡 |
| [hd5-case-report](hd5-case-report/SKILL.md) | 固定 8 節結案報告 |
| [hd5-workitem](hd5-workitem/SKILL.md) | Azure DevOps 工單工具與工單閘（`-Tracker azure-devops` 才裝） |
| [hd5-architecture](hd5-architecture/SKILL.md) | 架構健檢（僅使用者啟動，只規劃不寫碼） |

## 裝進 repo 的東西

| 位置 | 內容 |
|---|---|
| `.claude/skills/`、`.agents/skills/` | 技能（Claude 與 Codex 各一份） |
| `AI_Service/hd5-tools/` | 關卡工具與 hook（只有一份）：`validate-grill-gate.ps1`、`verify-map-check.ps1`、`check-guard-refs.mjs`、`hooks/grill-gate.ps1`、`hooks/main-edit-guard.ps1` |
| `.claude/agents/` | pm／sa／qa-expert、實作代理 |
| `.claude/workflow.json` | 實作代理與它們管哪些檔、產品程式範圍、工具位置、分支、工單系統 |
| `.claude/settings.json` | 註冊兩支 hook（只合併，不動其他設定） |
| `AI_Service/spec/`、`AI_Service/verify/` | 案子、功能地圖 |

## 需求

- Git、PowerShell 7（`pwsh`，Windows／macOS／Linux 都有）、Node.js 18+
- Codex 沒有 hook：Codex 派發前要顯式跑質詢閘（AGENTS.md 會寫明）

## 測試

```powershell
& ./HD5Skills/tests/install.tests.ps1                         # 安裝＋導入鏈（暫存 repo）
node HD5Skills/hd5-onboard/scripts/scan-repo.mjs --selftest
node HD5Skills/hd5-onboard/scripts/check-onboard.mjs --selftest
& ./HD5Skills/hd5-workflow/tools/tests/validate-grill-gate.tests.ps1
& ./HD5Skills/hd5-workflow/tools/tests/verify-map.tests.ps1         # 功能地圖檢查器（佔位符判定等）
& ./HD5Skills/hd5-workflow/tools/hooks/tests/grill-gate.tests.ps1
& ./HD5Skills/hd5-workflow/tools/hooks/tests/main-edit-guard.tests.ps1
```

## 改套件的規則

通用的不准寫死專案資料夾、代理名、副檔名、技術名詞——工具一律從 `.claude/workflow.json` 讀（`_hd5-locate.ps1` 往上找）。
專案事實寫進該 repo 的 AGENTS.md，不寫進技能。
