---
name: hd5-onboard
description: 把 HD5 工作流導入一個 repo（新專案或既有專案、任何程式技術）：掃描專案整理出詳細架構，一題一題問使用者補掃描推不出來的事，產生 Claude 與 Codex 共用的 AGENTS.md（主檔）、引用它的 CLAUDE.md、實作代理（含本專案技術架構重點）、.claude/workflow.json、功能地圖，最後用檢查腳本把關。使用者說「導入工作流」「初始化這個 repo」「幫這個專案產生 CLAUDE.md／AGENTS.md」「掃描專案架構」時使用；套件 -Update 後說「更新代理」時，合併代理檔的衝突小節（第 7 節）。
---

# hd5-onboard：把工作流導入這個 repo

流程規則在 `hd5-workflow`，跟技術無關；本 skill 負責產生**這個專案**的事實檔。
做完的定義：`node <本 skill>/scripts/check-onboard.mjs --project <專案資料夾>` 合格（exit 0），且結果已向使用者報告。

## 0. 前提

- 已跑過 HD5Skills 的 `install.ps1`（專案裡有 `AI_Service/hd5-tools/`、`.claude/skills/hd5-workflow/`、`.agents/skills/hd5-workflow/`、`.claude/settings.json` 的兩支 hook）。
  沒有就請使用者先跑：`& <HD5Skills>/install.ps1 -RepoRoot <repo> [-ProjectDir <子資料夾>]`。
- 專案資料夾＝`.claude/` 所在的那層（Claude Code 在這裡啟動）。repo 根＝git 根，可能跟專案資料夾不同。

## 1. 掃描（客觀事實）

```
node <本 skill>/scripts/scan-repo.mjs --root <repo 根> [--project <專案資料夾>] --out AI_Service/onboard/scan.json --md AI_Service/onboard/scan.md
```

掃描只給證據：語言、框架、建置／測試指令、CI、目錄、前後端分界、路由線索、既有 AI 入口檔（repo 根往下 3 層內所有 CLAUDE.md／AGENTS.md，
子資料夾若自己是 git repo／worktree 會跳過）、分支模型、工單線索、候選陷阱、要問的題目。

🔴 **掃描完第一件事：問使用者分支怎麼命名**（開發分支、工作分支前綴、測試／正式分支、AI 可以 push 哪些），用選擇題；
建議選項的來源依序：`scan.json` 的 `git.branchHintsFromDocs`（掃描從 README／CONTRIBUTING 等文件抓到的分支命名，附出處）→ 掃到的實際分支；
文件寫的跟實際分支不一致時，兩個都列成選項並註明出處；
答案寫進 workflow.json 的 `branches`（`develop`、`workBranchPrefix`、`test`、`production`）。之後每張單開分支都照這個命名，main-edit-guard 也靠它判斷「現在是不是工作分支」。（守衛：check-onboard.mjs）

掃描結果是**候選**：後端根可能混進暫存資料夾、候選陷阱要你讀程式確認。寫進產物前先篩過，篩掉的在 `architecture.md` 註明理由。

## 2. 讀懂架構（你判斷）

依 `scan.md` 挑著讀，不要整個 repo 讀過一遍：
- 既有 AI 入口檔（`scan.md`「既有 AI 入口檔」**每一份**都要讀）、README、.cursorrules
- 每個專案描述檔（package.json、*.csproj、pyproject…）、CI 設定
- 每一層挑 1～2 支代表檔：一支 API／控制器、一支頁面／元件、一支測試、資料存取層——看命名、分層、測試寫法、設定怎麼讀
- 🔴 不讀 `appsettings*.json`、`.env` 這類含密碼的檔；要知道設定鍵名就用搜尋取單一鍵，不印值（守衛：無（讀哪支檔無法事先攔））

把結論寫進 `AI_Service/onboard/architecture.md`：分層、模組、資料流、外部相依、測試分層、建置／部署方式；**每一條附證據（檔:行）**。

🔴 **沒有 AI 入口檔（CLAUDE.md／AGENTS.md／.cursorrules 都沒有）時，規則藏在流程類文件裡**：搜尋 README、`docs/`、CONTRIBUTING、
交接／決定紀錄（ADR、HANDOFF、會議紀錄）等，找含「一律／不可／禁止／必須／不要／規則」（英文文件加 must／never／always／do not）的段落，
整理成 `architecture.md` 的 `## 既有規則清單` 表（`| 規則 | 出處（檔:行） |`，一條一列）；第 4 步照樣寫去向表 `rules-migration.md`。
check-onboard 看到清單有表格列就要求去向表、且列數不少於清單。（守衛：check-onboard.mjs）

**既有文件互相矛盾**（例：兩份對 CI 觸發分支、測試指令寫法不同）：以較新的為準，並讀程式或設定檔驗證；
每一處衝突列進 `architecture.md` 的「既有文件衝突」表（說法 A｜說法 B｜採用｜依據），第 3 步給使用者確認。

## 3. 問使用者

題目來源：`scan.md` 的「要問使用者」＋你讀完還不確定的事＋第 2 步的衝突表。

- **既有文件已經有答案的**：標「已查證（出處 檔:行）」，**整批列給使用者一次確認**（使用者說要改哪幾題再逐題問）。
- **查不到的**：一次一題，用選擇題（附建議與理由）；前提先查證再問。
- 至少要確認：
  - 測試怎麼跑才安全（有沒有會寫共用資料的測試）
  - 完整測試要跑多久、日常怎麼縮範圍
  - **規格正本在哪、何時併回**：專案有沒有固定的規格位置（例：`sa/<上下文>/*.feature` 直接編進測試專案、`docs/specs/`）；
    有的話，案子資料夾裡的 SA 產物由誰（SA／實作代理／主對話）、在什麼時候（派實作前／合併前／結案時）併回那裡。答案寫進 AGENTS.md「AI 協作流程」的「規格正本」
  - 部署方式、工單系統、哪些動作一定要人決定、已知的坑
- 每題記進 `AI_Service/onboard/onboard-grill.md` 的表格：`| # | 題目 | 答案 | 狀態 |`，狀態＝已拍板／已查證／待問／🟨 待補。
  列了題目還沒問的標「待問」；🔴 **還有「待問」就不進第 4 步**——check-onboard 會擋；問了使用者也答不出來的才標 🟨 待補（只警告，要列給使用者）。（守衛：check-onboard.mjs）

## 4. 產生檔案

範本在 `<本 skill>/templates/`。🔴 **專案原本就有的檔一律先複製到 `AI_Service/onboard/backup/`**（保留原路徑結構），新舊差異摘要給使用者看，**使用者同意後才覆蓋**。（守衛：check-onboard.mjs、無（是否已取得使用者同意要靠人））

`install.ps1` 剛放進來的預設檔（`.claude/workflow.json`、`.claude/agents/*.md` 範本、`.claude/settings.json` 的兩支 hook）**不必備份**——那不是專案原本的東西。
判斷「是不是專案原本就有」：
1. 先看 git：`git log --oneline -1 -- <檔>` 有紀錄（裝之前就已 commit）＝原本就有；未追蹤（`git status` 顯示 `??`）且沒有紀錄＝多半是 install 放的。
2. 再比內容：跟 `<HD5Skills>/hd5-onboard/templates/` 對應範本逐字相同（`workflow.json` 對 `workflow.json.tpl`、`agents/<名>.md` 對 `agents/<名>.md` 或 `<名>.template.md`）＝install 放的預設，直接改寫。
3. `.claude/settings.json` 是合併寫入：裝之前就存在（git 有紀錄）就備份整份；只有 install 加的兩支 hook 就不用。
兩個判斷不一致（例：已 commit 但內容等於範本＝之前裝過、沒改過）就當預設檔處理，並在回報寫一行。

1. **`.claude/workflow.json`**（`workflow.json.tpl` 為底，欄位語意見檔內 `_說明`）：`stack` 寫技術名（例 `python-fastapi-react`）；
   `implementers` 依架構決定——後端＋前端就 backend-expert／frontend-expert，只有一層就只留一個，可再加（例 mobile-expert）；
   每個寫清楚 `extensions` 與 `pathHints`；`productCode.extensions` 要涵蓋所有實作代理的副檔名；
   `productCode.excludeDirs` 只比**相對專案資料夾的前綴**（`scripts/` 不會排除 `frontend/scripts/`），要排除任意層寫 `**/`（例 `**/node_modules/`）；
   測試資料夾歸 QA 時用 `roleHints`（例 `[{ "agent": "qa-expert", "pathHints": ["tests/"] }]`；主對話改測試檔時 main-edit-guard 建議派 qa-expert）；`tracker`（type＋url）、`branches` 照使用者回答（第 1 步一開始問的分支命名；空的 check-onboard 會擋）。
   使用者選 Azure DevOps 時，請使用者重跑 `install.ps1 -RepoRoot <repo> [-ProjectDir …] -Tracker azure-devops`（補裝 `hd5-workitem` 工單工具，並把 tracker.type 寫進 workflow.json），再填 `tracker.url`。
   專案原本就有代理名稱（例 csharp-expert）時，放進 `aliases`／`gateAliases` 當過渡期別名。
2. **`AGENTS.md`**（`AGENTS.md.tpl`）：每個 `{{…}}` 換成實際內容；推不出來、使用者沒答的寫「🟨 待補」。
   - 「建置、測試與執行指令」節的**相依套件弱點掃描**那一行：依掃描到的套件管理工具填（npm／pnpm／yarn audit、`dotnet list package --vulnerable --include-transitive`、pip-audit、`go run golang.org/x/vuln/cmd/govulncheck`…），
     寫清楚要不要連網、多久跑一次；專案真的沒有第三方套件才寫「無（理由）」。獨立驗收的委託檔會附它的結果（`hd5-review`）。check-onboard 沒看到會警告。
   - 既有入口檔的**每一條規則**都要有去處：放進 AGENTS.md 對應小節；放不進 8 個小節的（例：收尾工作流細節、派發範本），
     留在原文件並從 AGENTS.md 用一行指過去；已被新版推翻的規則不搬，但要列出來給使用者確認。
   - 寫 **`AI_Service/onboard/rules-migration.md`**（既有規則去向表）：`| 規則 | 原出處（檔:行） | 去向（AGENTS.md 哪一節／留在哪份文件／不搬＋理由） |`，
     每條一列（既有入口檔的規則＋第 2 步「既有規則清單」的規則）。check-onboard 會擋「有備份或有既有規則清單，卻沒有去向表／列數不夠」。
   - 回報規則、完工定義、心跳約定這類放不進固定小節的通用規則，放在「AI 協作流程」底下用 `###` 分節。
   - 保留範本「AI 協作流程」裡 Codex 擔任角色那一條（讀 `.claude/agents/<角色>.md` 本文、忽略 tools／model；專案自有 skill 讀 `.claude/skills/<名>/SKILL.md`）——
     Codex 沒有子代理定義，這是它當 pm／sa／實作／qa 的唯一依據；check-onboard 沒看到 `.claude/agents` 會警告。
3. **`CLAUDE.md`**（`CLAUDE.md.tpl`）：第一行一定是 `@AGENTS.md`；只放 Claude 專屬（子代理、hook、瀏覽器工具、啟動位置）。
4. **repo 根與專案資料夾不同時**：Codex 會從 repo 根一路載入每層的 AGENTS.md、Claude 也會讀上層的 CLAUDE.md——規則會疊兩份。
   repo 根原有的 CLAUDE.md／AGENTS.md 內容併進專案資料夾的 AGENTS.md 後，建議把 repo 根那兩份縮成「只放整個 repo 共用的規則，
   或一行指向 `<專案資料夾>/AGENTS.md`」；**改之前問使用者**。repo 根的 CLAUDE.md 以 `templates/root-CLAUDE.md.tpl` 為底：
   一定要寫「**必須在 `<專案資料夾>/` 啟動，否則停下請使用者重開**」——不要寫「先切到 `<專案資料夾>/`」：Claude Code 只在啟動時從啟動目錄載入
   `.claude/agents` 與 settings 的 hook，事後 `cd` 不補載，而 skills 照樣讀得到，所以要到派代理才會暴露，hook 整段沒生效也沒有訊號（11-24 試跑實例）。
   - **選配：repo 根的 SessionStart 警告**（建議開；問使用者）：把 `templates/root-settings.sessionstart.json` 的 `hooks.SessionStart`
     合併進 `<repo 根>/.claude/settings.json`（已存在就先備份；`{{PREFIX}}`＝專案資料夾加斜線，`{{PROJECT_DIR}}`＝專案資料夾；`_說明` 不搬）。
     它只看啟動目錄在不在專案資料夾內，不在就顯示「請改在 `<專案資料夾>/` 重新啟動」並告訴 AI 先停下；永遠 exit 0、不擋，跟技術無關。
     限制：它只在讀到這份 settings 的 session 觸發（從 repo 根啟動）；從其他無關資料夾啟動、或 repo 根的 `.claude/` 被 `.gitignore` 排除（worktree 拿不到）時不會觸發——
     所以 root CLAUDE.md 的那一行文字仍然要寫。檔案要 commit 進版控，新 worktree 才會帶著。
5. **代理**（`.claude/agents/`）：
   - 專案**已有**同名或對應的代理檔（例 csharp-expert）：**保留原本的本文與 frontmatter（model、tools…）**，新檔以它為底，
     只補缺的小節（例：實作代理的「程式設計原則」、sa-expert 質詢對象的「設計形狀」分支）；原檔名當別名保留（workflow.json 的 aliases），檔頭描述標「已改名為 xxx」。
     🔴 **「寫入路徑限制」一節要跟範本對齊**：保留舊本文時，範本後來加的寫入權限（例：sa-expert 要能建功能地圖骨架 `<AI_Service>/verify/features/`）
     也要補進去，否則流程要它寫、限制又不准寫（11-24 試跑實例）。check-onboard.mjs 會在 sa-expert 流程提到 verify/features、寫入限制卻沒放行時警告。（守衛：check-onboard.mjs）
   - 沒有的：以 `templates/agents/*-expert.template.md` 為底，`name` 改成 workflow.json 的 agent 名。
   - 最後一節「本專案技術架構重點」寫 15～40 行這個專案的關鍵規則（語言版本、分層、資料存取的坑、測試寫法、建置指令、不能做的事）。
     🔴 子代理實測很少讀 skills（9/28），**關鍵規則一定要寫在代理本文**，不能只寫「見某份文件」。（守衛：check-onboard.mjs）
6. **功能地圖**（`AI_Service/verify/`）：
   - 專案**已有**功能地圖、且 `& ./AI_Service/hd5-tools/verify-map-check.ps1` 合格 ⇒ 沿用，只改工具路徑。
   - 沒有的：用掃描的路由線索挑 3～8 個主要功能，**只建你讀程式說得出實際操作步驟的功能**（從哪個網址／畫面進去、按什麼、成功長怎樣）。
     說不出步驟的**不要建檔**（地圖檢查會把「待補／TODO」當佔位符擋下），列進回報的「待建功能」清單。
   - 登入步驟的帳密寫「由使用者輸入」或「讀環境變數 `X`」（只寫變數名、不寫值）；AI 不讀密碼檔、不代打密碼（`hd5-verify` 第五節）。
     這兩種寫法不算佔位符；指令裡的 `{{…}}`（docker `--format`、Go template）放在反引號或程式碼區塊內也不算。

## 5. 把關

```
node <本 skill>/scripts/check-onboard.mjs --project <專案資料夾>
& ./AI_Service/hd5-tools/verify-map-check.ps1
& ./AI_Service/hd5-tools/hooks/tests/main-edit-guard.tests.ps1
& ./AI_Service/hd5-tools/hooks/tests/grill-gate.tests.ps1
```

不合格就修到合格。🟨 待補可以留，但要列給使用者。

## 6. 回報

- 產生／修改了哪些檔
- 架構摘要（3～6 行）與實作代理分工
- 「已查證」題目清單（請使用者一次確認）、🟨 待補清單、既有文件衝突表、被新版推翻而沒搬的規則
- 待建功能清單（功能地圖還沒建的）
- 檢查結果（照實貼數字）
- 下一步：commit（由使用者決定）、repo 根入口檔要不要縮、用 `hd5-workflow` 開第一張單
- 選配建議：問使用者要不要裝 commit 前的密鑰掃描（`install.ps1 -RepoRoot … [-ProjectDir …] -Update -InstallPreCommit`，由使用者自己跑；專案已有別的 pre-commit 時不會覆蓋，會印出要加的那一行）。沒有工單系統的專案特別建議裝，因為沒有工單閘替它再掃一次

不要自己 commit 或 push。之後套件更新用 `install.ps1 -Update`（更新套件的 skills 與工具；代理檔以小節三方比對，見第 7 節）。

## 7. 更新代理（`install.ps1 -Update` 之後）

使用者說「更新代理」「合併代理範本」，或 `-Update` 印出「代理檔有 N 節要人工合併」時用。

`-Update` 已經把代理檔（`.claude/agents/*.md`）專案沒改過的小節換成新範本、補上範本新加的小節；剩下**專案與範本都改過**
（或沒有基準可比）的小節列在 `<aiService>/onboard/agent-update.md`，每節附三個版本：基準（上次同步的範本）、專案現在、新範本。
**沒有基準時（第一次跑）範本有、專案沒有的節不會自動插入**，也列在報告裡，並點名專案裡標題相近的節：那常是專案用別的標題寫的同義節，
合併時二選一（把範本的新規則併進專案那一節，或改用範本的節並刪掉舊的），不要兩節並存。沒有基準又有衝突時也不建基準，`-AcceptAgents` 之後才建。
基準存在 `<aiService>/onboard/agent-base/`（要進版控，新 worktree 才比得到）。

1. 讀 `agent-update.md`，一個代理一個代理處理。每一節判斷：
   - 範本的改動是**新規則或流程修正**（基準→新範本的差異）⇒ 採用；
   - 專案的改動是**專案事實或刻意調整**（基準→專案現在的差異，例：改名、專案限制、多加的步驟）⇒ 保留；
   - 兩者互相矛盾 ⇒ 不自己決定，列成選擇題一題一題問使用者（附建議）。
2. 合併後的內容寫回該代理檔的那一節；「本專案技術架構重點」不動。給使用者看每一節的前後差異，**使用者同意才寫入**。
3. 一個代理全部處理完，執行報告開頭那行指令（`install.ps1 … -Update -AcceptAgents <代理名>`）：
   把該代理的基準設成目前範本，衝突就不再列。不要手改 `agent-base/` 底下的檔。
4. 跑 `node <本 skill>/scripts/check-onboard.mjs --project <專案資料夾>` 確認代理檔還合格，回報改了哪些節。
