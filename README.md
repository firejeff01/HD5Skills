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

已導入過的專案，套件出新版時用 `-Update`：把套件擁有的檔（`.claude/skills/hd5-*`、`.agents/skills/hd5-*`、`paths.tools` 底下的工具；
工單工具只在 `tracker.type`＝azure-devops 時）覆蓋成新版，**不動** AGENTS.md、CLAUDE.md、`workflow.json`、`settings.json`、
spec／verify 與 PAT 檔；不刪檔，套件已不含的檔只列出來請你確認。

**代理檔（`.claude/agents/`）以「## 小節」三方比對**（2026-11-28）：基準（上次同步的範本，存在 `AI_Service/onboard/agent-base/`，要進版控）／新範本／專案現在。

| 情況 | 處理 |
|---|---|
| 範本新加的節，專案沒有 | 自動插入（接在範本裡前一節的後面） |
| 範本改了，專案沒改過 | 自動換成新版 |
| 專案改過，範本沒改 | 保留專案的 |
| 兩邊都改了，或沒有基準可比（本功能上線前導入的專案第一次跑） | 不動，列進 `AI_Service/onboard/agent-update.md` |
| 「本專案技術架構重點」 | 永遠不動 |

有衝突時，在專案啟動 Claude Code 說「更新代理」（`hd5-onboard` 第 7 節）：AI 逐節合併、你同意才寫入，某個代理合併完再跑 `-AcceptAgents <代理名>`。
實作代理靠 `workflow.json` 的 `gateRole`（backend／frontend）對到範本；其他 gateRole 不比對，只列提醒。

```powershell
& ./HD5Skills/install.ps1 -RepoRoot D:\work\MyRepo [-ProjectDir src\MyApp] -Update
& ./HD5Skills/install.ps1 -RepoRoot D:\work\MyRepo [-ProjectDir src\MyApp] -Update -AcceptAgents sa-expert   # 合併完 sa-expert 的衝突後
& ./HD5Skills/install.ps1 -RepoRoot D:\work\MyRepo [-ProjectDir src\MyApp] -Update -InstallPreCommit         # 選配：commit 前掃密鑰（已有別的 pre-commit 不覆蓋）
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
| `AI_Service/hd5-tools/` | 關卡工具與 hook（只有一份）：`validate-grill-gate.ps1`、`verify-map-check.ps1`、`check-guard-refs.mjs`、`check-rework-ledger.mjs`（退回總帳對帳）、`check-secrets.mjs`（密鑰掃描）、`hooks/grill-gate.ps1`、`hooks/main-edit-guard.ps1` |
| `.claude/agents/` | pm／sa／qa-expert、實作代理 |
| `.claude/workflow.json` | 實作代理與它們管哪些檔、產品程式範圍、工具位置、分支、工單系統 |
| `.claude/settings.json` | 註冊兩支 hook（只合併，不動其他設定） |
| `AI_Service/spec/`、`AI_Service/verify/` | 案子、功能地圖 |

## 防線的優先序（2026-11-25）

糾正一次就變成確定性檢查（Lauren Tan）：產品程式架構（型別／API／目錄邊界）→ 靜態檢查（棘輪、lint、架構測試）→ 自動化驗證 → 流程閘 → 文字。

- **會擋人的流程閘**只有質詢閘 exit 2～13、功能地圖、工單閘（獨立驗收／站上關卡通過、退回紀錄與上線後缺陷 `check-rework-ledger.mjs --gate`、密鑰掃描 `check-secrets.mjs`）。密鑰掃描送獨立驗收前由主對話先跑一次，改待驗收時工單閘再用委託檔的受驗範圍自動跑一次；選配 `-InstallPreCommit` 再加一道 commit 前的掃描。
- **退回檢討循環**：每次驗收退回記 `qa/rework-log.md`（含「錯誤寫法」欄）→ 驗收完成時結案報告 5.1＋專案總帳 `AI_Service/spec/rework-ledger.md`；
  程式寫法類的根因第一次就要對應程式守衛（或 `待辦（G-NN）`），否則 `check-rework-ledger.mjs --check`（verify）紅，不擋工單結案。
- **上線後才發現的缺陷**（2026-11-28）：走小問題路線修，SA 寫 `逃逸：是，來源 #NNN`；結案時總帳記一列 來源案、輪次＝`上線`，工單閘與 `--check` 會對。
- **資安掃描**（2026-11-28）：送獨立驗收前跑 `check-secrets.mjs --diff <起點>..<終點>`（密鑰），加上 AGENTS.md 寫的相依套件弱點掃描，結果附在委託檔；有發現列 P0。
- **只警告、不擋**（需求溝通與人工步驟，擋了容易被敷衍或繞過；真正的防線在產品程式層）：
  - 質詢閘先印一行「grill-gate 警告摘要：共 N 項（類別…）」，再逐項印「grill-gate 警告：[i/N] …」（派發 hook 帶進放行訊息）：`spec_*.md` 沒寫「外部系統：有｜無」（建議寫在路線那一行：`路線：…，高風險：…，外部系統：無，理由：…`）；外部系統＝有但 `sa/external-samples.md` 缺或樣本不齊；rework-log 有「新規則」退回但 grill 沒有收斂完的「驗收回合 R{k}」小節；四角色／PM 端已完成但 SA 的 grill 沒有收斂的「設計形狀」小節；小問題的 `sa/bug-analysis.md` 沒寫「逃逸：」；`qa/rework-log.md` 同一根因類別連兩輪卻沒有「前提檢查 R{k}：」。
  - 站上關卡（`verify-map-check.ps1 -Onsite` 與工單閘）印「⚠ 站上關卡警告（不擋）：…」：退回後沒有（新打通）列，寫 `新打通：無（理由）` 消除；同一項連兩輪「未驗證（待使用者動作）」，寫 `使用者放行：<項目>…（MM-DD）` 消除。
  - 外部系統每種變化要有**產品程式層的樣本契約測試**，站上不再逐種列 A 項。

## 需求

- Git、PowerShell 7（`pwsh`，Windows／macOS／Linux 都有）、Node.js 18+
- `install.ps1` 與 hook 只用 pwsh；質詢閘、功能地圖檢查、工單工具與各 lib 也要能在 Windows PowerShell 5.1 跑（Codex 可能用 5.1）
- Codex 沒有 hook：Codex 派發前要顯式跑質詢閘（AGENTS.md 會寫明）

## 測試

```powershell
& ./HD5Skills/tests/install.tests.ps1                         # 安裝＋導入鏈（暫存 repo）
node HD5Skills/hd5-onboard/scripts/scan-repo.mjs --selftest
node HD5Skills/hd5-onboard/scripts/check-onboard.mjs --selftest
& ./HD5Skills/hd5-onboard/scripts/tests/agent-merge.tests.ps1      # 代理檔三方比對（-Update）
& ./HD5Skills/hd5-workflow/tools/tests/validate-grill-gate.tests.ps1
& ./HD5Skills/hd5-workflow/tools/tests/verify-map.tests.ps1         # 功能地圖檢查器（佔位符判定等）
& ./HD5Skills/hd5-workflow/tools/hooks/tests/grill-gate.tests.ps1
& ./HD5Skills/hd5-workflow/tools/hooks/tests/main-edit-guard.tests.ps1
node HD5Skills/hd5-workflow/tools/check-guard-refs.mjs --selftest
node HD5Skills/hd5-workflow/tools/check-rework-ledger.mjs --selftest      # 退回總帳／rework-log／5.1／上線後缺陷 對帳
node HD5Skills/hd5-workflow/tools/check-secrets.mjs --selftest            # 密鑰掃描
& ./HD5Skills/tests/repo-hygiene.tests.ps1                               # 所有 .ps1 有 BOM、文字檔沒有控制字元（pwsh 與 5.1 都要跑）
& ./HD5Skills/hd5-workitem/scripts/tests/workitem-ops.tests.ps1           # 工單工具（假 API）；devops-lib.tests.ps1 同
```

## 改套件的規則

通用的不准寫死專案資料夾、代理名、副檔名、技術名詞——工具一律從 `.claude/workflow.json` 讀（`_hd5-locate.ps1` 往上找）。
專案事實寫進該 repo 的 AGENTS.md，不寫進技能。
`.ps1` 一律存成 **UTF-8 with BOM**：Windows PowerShell 5.1 讀沒有 BOM 的檔會用系統字碼頁（Big5），中文變亂碼，測試解析失敗、中文比對字串靜默失效。`tests/repo-hygiene.tests.ps1` 會檢查。測試要 7 與 5.1 都能跑的，不要用 .NET Core 才有的 API（`[Environment]::ProcessPath`、`ProcessStartInfo.ArgumentList`、`StandardInputEncoding`）。
