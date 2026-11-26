---
name: hd5-workitem
description: Azure DevOps 工單工具（跟程式技術、跟專案無關）。讀工單建案（標題／描述／圖片／附件／引用工單 → AI_Service/spec/<案名>/）、看工單與留言、留言（討論串或 System.History）、指派、改狀態（含上層工單一起改）、改「待驗收」前自動過工單閘（獨立驗收結果、站上關卡報告、功能地圖、Pass 有證據）、上傳結案報告 ai-case-report.md 到工單附件（上傳前同樣過工單閘）。使用者貼工單網址或號碼要建案、說「在工單留言」「指派給…」「改成待驗收」「上層也一起改」「上傳結案報告」、或查某張工單的狀態／留言／人員帳號時使用。專案沒有設定 Azure DevOps（.claude/workflow.json 的 tracker.type 不是 azure-devops）時不適用。
---

# hd5-workitem — Azure DevOps 工單工具

> **適用對象**：主對話。pm／sa／實作／qa 代理**不寫工單**——代理只回報「該留什麼言、該改什麼狀態」，寫入由主對話做。
> 讀工單建案（唯讀）可以由主對話或建案流程做。
> 工單系統種類、專案網址、權杖放哪裡等專案事實在 `.claude/workflow.json` 的 `tracker` 與該 repo 的 `AGENTS.md`；本 skill 只講方法。

## 一、需求

- **Windows PowerShell 5.1 或 PowerShell 7（pwsh）**。腳本都存成 UTF-8 with BOM（5.1 少了 BOM 會把中文讀成亂碼而語法錯誤，改檔後要補回）。
- **Azure DevOps 權限**：
  - 雲端（`dev.azure.com`）：**PAT**。讀工單＝Work Items - Read；留言／指派／改狀態／上傳＝Work Items - Read & Write。
  - 自架 Azure DevOps Server：四支腳本在 PAT 都沒設時改用 **Windows 整合驗證**（目前登入帳號）。雲端（`dev.azure.com`、`*.visualstudio.com`）或非 Windows 沒有整合驗證，沒 PAT 就報錯說明怎麼設。
- `.claude/workflow.json`：`tracker.type` 要是 `azure-devops`、`tracker.url` 填專案網址 `https://host/{organization 或 collection}/{project}`。
- 工單閘還需要 HD5 工具資料夾裡的功能地圖檢查器 `_verify-map-lib.ps1`（`hd5-workflow` 安裝時一起裝；位置＝workflow.json 的 `paths.tools`）。

## 二、鐵則

1. **對外動作先讓使用者同意**：留言、指派、改狀態、上傳結案報告都是寫到別人看得到的地方。
   一律先預覽（`workitem-ops.ps1 … -WhatIfOnly`、`upload-case-report.ps1` 不帶 `-Upload`）→ 把預覽給使用者看 → 使用者同意才正式執行（`hd5-workflow`「對外動作由人決定」）。（守衛：workitem-ops.ps1、upload-case-report.ps1）
2. **改「待驗收」前、上傳結案報告前都要過工單閘**（下面第五節，同一套），沒過不改、不傳。沒有案子（例：緊急修正）且使用者同意略過時才用 `-SkipAcceptanceGate "<理由>"`，理由不可空白、略過會明講印出。（守衛：workitem-ops.ps1、upload-case-report.ps1）
3. **PAT 不進版控、不印出、不代設**：PAT 只放環境變數或本機 PAT 檔；腳本只印「認證來源」不印 PAT。不要讀或顯示 PAT 檔內容；使用者沒設 PAT 時告訴他怎麼設，不要代打。（守衛：devops-lib.tests.ps1、無（腳本裡的 .gitignore 排除 PAT 檔；有沒有人把 PAT 貼進對話擋不住））
4. **留言用使用者本人的口吻**：留言會以目前登入者（或 PAT 擁有者）的名義出現。寫給需求方看的要白話、列「驗收前要先做的事」、不寫內部代號；不寫連線字串、帳密、權杖、內網主機明細，不寫「AI 代為…」。（守衛：無（內容好壞要人看預覽判斷））
5. **一律用 `&` 在目前 session 執行**腳本；若有沙箱擋對外連線，呼叫時要關沙箱（或請使用者在自己的終端機跑）。不要在對話裡手組 `Invoke-RestMethod` 打 API——走腳本才有預覽、狀態驗證與工單閘。（守衛：無（環境規則））
6. 🔴 **退回要記帳才能再送驗、驗收完成要補 5.1 與總帳**：改「待驗收」時工單閘讀工單歷程，退回（`tracker.rejectedStates`）k 次而 `qa/rework-log.md` 記不到 k 輪就擋；
   改「驗收完成」（`tracker.doneStates`）或工單已驗收完成後上傳結案報告時，報告 5.1、rework-log、退回總帳列數對不上就擋（第五節「退回紀錄閘」）。（守衛：_acceptance-gate.ps1、check-rework-ledger.mjs）
## 三、腳本（裝在 `<paths.tools>/workitem/`，預設 `AI_Service/hd5-tools/workitem/`）

| 檔案 | 用途 |
|---|---|
| `workitem-ops.ps1` | 入口：`-Action show｜states｜comments｜whoami｜find-user｜update`（看工單、狀態集、留言、目前身分、查人員帳號、寫入） |
| `fetch-workitem.ps1` | 讀工單建案：`-PeekOnly` 先看內容（不落檔）→ `-CaseName` 正式建 `spec/<案名>/`（case_spec_content、pm、sa、pg、qa） |
| `fetch-related-attachments.ps1` | 按需下載引用工單的附件到 `case_spec_content/related/{工單號}/attachments/` |
| `upload-case-report.ps1` | 上傳結案報告 `ai-case-report.md` 到工單附件；**預設只預覽，`-Upload` 才上傳，上傳前過工單閘** |
| `_auth.ps1` | 認證（唯一一份）：四支腳本共用，PAT 或 Windows 整合驗證 |
| `_tracker-config.ps1` | 共用：往上找 `.claude/workflow.json`、讀 tracker、推專案網址、找功能地圖檢查器 |
| `_acceptance-gate.ps1` | 工單閘（唯一一份）：改待驗收、改驗收完成與上傳結案報告共用；退回紀錄閘呼叫上一層的 `check-rework-ledger.mjs` |
| `_workitem-ops-lib.ps1`、`_devops-lib.ps1` | 共用函式（不可直接執行） |
| `pat.local.example.txt`、`.gitignore` | PAT 檔範本；排除 `pat.local.txt`、`pat.write.local.txt` |
| `tests/workitem-ops.tests.ps1`、`tests/devops-lib.tests.ps1` | 離線測試（假 API，不連網、不需 PAT）。**改過腳本必跑，5.1 與 7 最後一行都要 `ALL PASSED`** |

## 四、設定從哪裡來

**專案網址**（只給工單號碼時）依序取：`-ProjectUrl` → 環境變數 `AZURE_DEVOPS_PROJECT_URL` → `.claude/workflow.json` 的 `tracker.url`。都沒有就報錯並列出三種給法。
給完整工單網址（`/_workitems/edit/NN`、`…?workitem=NN`、`/_apis/wit/workItems/NN`）時以網址為準。

**設定檔**（往上找 `.claude/workflow.json`）起點優先序：**參數 > 目前工作目錄 > 腳本位置**——
有給 `-ConfigStart` 就只從它往上找（找不到＝沒有設定檔，不再退到其他起點）；沒給就依序 `-CasePath` → 目前工作目錄 → 腳本所在資料夾，第一個找得到的為準。
（測試會先把腳本複製到上層沒有設定檔的暫存資料夾再跑，放在套件裡或裝進專案結果相同。）
找到了但 `tracker.type` 不是 `azure-devops`（含沒寫 tracker）⇒ 腳本拒絕：「本專案沒有設定 Azure DevOps」。
找不到設定檔（還沒導入 HD5）⇒ 不判斷 type，網址要用參數或環境變數給。

| workflow.json 欄位 | 用途 |
|---|---|
| `tracker.type` | `azure-devops` 才能用本工具 |
| `tracker.url` | 專案網址 |
| `tracker.acceptanceStates`（選填） | 除了含「待驗收」的狀態以外，還要過工單閘的狀態名（例：英文流程的 `["Ready for UAT"]`） |
| `tracker.rejectedStates`（選填） | 需求方退回的狀態名，預設 `["驗收未過"]`：工單歷程 State 變成它幾次＝退回幾次 |
| `tracker.doneStates`（選填） | 需求方最終驗收通過的狀態名，預設 `["驗收完成"]`：改成它、或工單已進過它時上傳結案報告，要過退回紀錄閘的 done 檢查 |
| `paths.aiService` | 案子 `spec/`、功能地圖 `verify/` 所在（預設 `AI_Service`） |
| `paths.tools` | HD5 工具資料夾（功能地圖檢查器在這裡；預設 `AI_Service/hd5-tools`） |

**認證**（四支共用 `_auth.ps1` 的 `New-DevOpsAuthContext`）依序取（找到第一個就用）：

| 順序 | 唯讀（`fetch-*.ps1`） | 寫入（`workitem-ops.ps1`、`upload-case-report.ps1`） |
|---|---|---|
| 1 | `-Pat` | `-Pat` |
| 2 | 環境變數 `AZURE_DEVOPS_PAT` | `AZURE_DEVOPS_PAT_WRITE` → `AZURE_DEVOPS_PAT` |
| 3 | `-PatFile <路徑>`（檔不存在就報錯） | `-PatFile` |
| 4 | 腳本資料夾的 `pat.local.txt` | `pat.write.local.txt` → `pat.local.txt` |
| 5 | Windows 整合驗證（UseDefaultCredentials） | 同左（`workitem-ops.ps1 -UseWindowsAuth` 可強制） |

第 5 步只在 Windows、而且網址不是雲端（`dev.azure.com`、`*.visualstudio.com`）時才用；否則沒 PAT 就報錯，訊息會列出三種設法和該組織的 PAT 申請網址。
PAT 檔＝一行 PAT（`#` 開頭與空白行略過），範本 `pat.local.example.txt`。放在腳本資料夾以外的位置就用 `-PatFile` 指過去。
申請：`<組織網址>/_usersSettings/tokens`（User settings → Personal access tokens）。

**憑證：預設不驗**（為了自架 Azure DevOps Server 的自簽憑證，同原版做法；PS7 帶 `-SkipCertificateCheck`、5.1 換成信任全部的 `ServicePointManager` policy，結束時還原）。
連雲端想驗證憑證就加 **`-StrictCertificate`**。（`-SkipCertificateCheck` 是相容舊參數，本來就預設略過。）
## 五、工單閘（改「待驗收」前、上傳結案報告前自動檢查）

兩個時機用**同一套**判定（`_acceptance-gate.ps1`），都**在連網之前**檢查 `-CasePath <AI_Service/spec/<案名>>`：
- `workitem-ops.ps1 -Action update`：`-State` 含「待驗收」（或等於 `tracker.acceptanceStates` 其中一個）時。
- `upload-case-report.ps1 -Upload`：正式上傳時。沒給 `-CasePath` 但有 `-CaseName`，且 `<SpecRoot>/<CaseName>` 資料夾存在時，自動用它當 `-CasePath`（會印出來）；不存在就照樣擋。

1. **獨立驗收通過**：`qa/` 根目錄的 `{Codex|Claude}驗收結果_[中綴_]R{n}[b].md`（`hd5-review` 的結果檔）取最新一輪（R1 < R1b < R1c < R2，數字比大小），
   檔內**最後一個** `總結：` 行是 `通過`（可接附註），或 `不通過` 但 P0、P1 都是 0。受阻、有條件通過、找不到總結行都擋。子目錄、`.raw.md` 不認（會提示搬到 `qa/` 根目錄）。
2. **站上關卡通過**：`qa/onsite-gate_[中綴_]R{n}[b].md`（`hd5-onsite-gate` 的報告）最新一輪，判法同上。
3. **功能地圖合格**：`<paths.aiService>/verify/`（或 `-VerifyRoot`）用功能地圖檢查器 `Test-VerifyMap` 檢查（`hd5-verify` 規格）。
4. **A 表對到功能、Pass 有證據**：站上關卡報告的 `## A. 驗收項目` 每條「功能」欄對到功能地圖編號、Pass 有證據檔（檔案要真的在 `onsite-gate_R{n}/` 或 `qa/`）或內嵌 `查詢：`／`API：`／`畫面值：`。
5. **檢查器找不到就 fail closed**：功能地圖檢查器位置＝`-ToolsDir` → workflow.json 的 `paths.tools` → 腳本資料夾的上一層；找不到 `_verify-map-lib.ps1` 就擋並列出找過的路徑，不會默默略過。

- 沒給 `-CasePath` ⇒ 擋（提示用 `-SkipAcceptanceGate "<理由>"` 的條件）。上傳的預覽模式例外：只印「正式上傳會被擋」。
- 預覽（`workitem-ops.ps1 -WhatIfOnly`；上傳沒帶 `-Upload` 或帶了 `-WhatIfOnly`）時工單閘沒過只印紅字「正式執行會被擋」與原因，讓使用者先看到；正式執行一定擋。
- `-SkipAcceptanceGate "<理由>"`：理由空白（含全是空格）不算，照樣要 `-CasePath`；有理由就略過並印出「已略過工單閘：理由…」。
### 退回紀錄閘（2026-11-25；讀完工單後判，因為要讀工單歷程）

判定本體是 HD5 工具資料夾的 `check-rework-ledger.mjs`（要有 node；找不到工具或 node 就 fail closed），工具位置同上（`-ToolsDir` → `paths.tools` → 上一層）。

| 時機 | 檢查 |
|---|---|
| `workitem-ops.ps1` 改「待驗收」 | 工單歷程 State 變成 `tracker.rejectedStates`（預設「驗收未過」）k 次 ⇒ `qa/rework-log.md` 要記滿 k 輪（`R1`、`R2`…，同輪多列算一輪），否則擋並說「要先記第幾輪退回」；k＝0 且沒有總帳就不跑 |
| `workitem-ops.ps1` 改 `tracker.doneStates`（預設「驗收完成」）；`upload-case-report.ps1` 上傳時工單目前是、或歷程進過驗收完成 | rework-log 有 m 列 ⇒ `ai-case-report.md` 有 `### 5.1` 且表格 m 列、有「錯誤寫法」欄（m＝0 要寫「退回 0 次」）、總帳 `AI_Service/spec/rework-ledger.md` 有本案案號 m 列；也核對 rework-log 輪數 ≥ 歷程退回次數。改驗收完成沒給 `-CasePath` 在連網前就擋 |
| 以上每次 | 總帳存在就一起跑 `--check --gate`：只查格式（8 欄、根因類別、錯誤寫法、對應規則寫法）與 rework-log／5.1／總帳對帳。「程式寫法類要有程式守衛、待辦拖著又再犯」**不在工單閘擋**，只在開發端 `--check`（verify）紅（`hd5-case-report` 第七節） |

預覽照樣只印「正式執行會被擋」；`-SkipAcceptanceGate "<理由>"` 一併略過。

- 工單閘**不檢查**、要人工核對的兩項（`hd5-onsite-gate` 第七節）：站上關卡報告的部署 commit 跟現在站上一致；留言稿列出全部 `未驗證` 項目與需要的資料。

## 六、動作

```powershell
$wi = "AI_Service/hd5-tools/workitem"     # 依 workflow.json 的 paths.tools

# 看工單：標題／型別／狀態／指派／上層鏈／附件／留言數
& "$wi/workitem-ops.ps1" "https://dev.azure.com/<org>/<project>/_workitems/edit/123"
& "$wi/workitem-ops.ps1" 123                          # 號碼：網址取 tracker.url

& "$wi/workitem-ops.ps1" 123 -Action states           # 這張工單「型別」允許的狀態（各型別不同）
& "$wi/workitem-ops.ps1" 123 -Action comments         # 留言（新→舊，含留言 id）
& "$wi/workitem-ops.ps1" 123 -Action comments -Id 4465,4467      # 只讀指定的留言
& "$wi/workitem-ops.ps1" 123 -Action comments -ExcludeId 4471    # 排除指定的留言（內容不印，只說排除了哪個 id）
& "$wi/workitem-ops.ps1" 123 -Action whoami           # 目前用誰的身分連（401／403 先看這個）
& "$wi/workitem-ops.ps1" 123 -Action find-user -Query "<姓名或帳號>"   # 指派用 Account 或信箱最穩

# 寫入：留言＋指派＋改待驗收，連同上層工單。🔴 先 -WhatIfOnly 預覽
& "$wi/workitem-ops.ps1" 123 -Action update -CommentFile ".\留言稿.html" -CommentHtml `
    -AssignTo "<帳號或信箱>" -State 待驗收 -CasePath "AI_Service/spec/<案名>" -IncludeParents -WhatIfOnly
# 預覽的目標工單、上層鏈、狀態、留言內容、工單閘結果都對，使用者同意 → 拿掉 -WhatIfOnly 正式執行
```

`update` 參數：

| 參數 | 說明 |
|---|---|
| `-Comment "文字"`／`-CommentFile 路徑` | 留言。預設當**純文字**（自動 HTML 編碼、換行轉 `<br/>`）；內容本身是 HTML 時加 `-CommentHtml` 原樣送出 |
| `-CommentVia comments｜history` | `comments`（預設）＝討論串留言，有留言 id；`history`＝寫進 `System.History` 欄位，跟指派／狀態**同一次** PATCH，並帶 `/rev` 檢查（預覽後工單被別人改過就整筆失敗，不會蓋掉別人的變更）。comments API 不能用的舊版 Server、或想讓留言跟狀態變更出現在同一筆歷程時用 |
| `-AssignTo` | 指派。給帳號（`DOMAIN\帳號`）或信箱（`find-user` 查）；顯示名同名時會錯人 |
| `-State` | 狀態名。**先對每張工單型別的狀態集驗證**，不存在直接拋錯並列出允許值，不會送出 |
| `-IncludeParents` | 沿父工單鏈（Hierarchy-Reverse）往上每一層都套用同樣的留言／指派／狀態；`-MaxDepth` 預設 10。上層鏈會一路走到頂，不要的層級就不要加，改逐張下指令 |
| `-WhatIfOnly` | 只印預覽，不寫入 |
| `-CasePath` | 要過工單閘的狀態**必填**：`AI_Service/spec/<案名>` |
| `-SkipAcceptanceGate "理由"` | 沒有案子且使用者同意時略過工單閘；理由印在預覽 |
| `-ToolsDir`、`-VerifyRoot`、`-ConfigStart` | 覆寫檢查器位置、功能地圖位置、設定檔起找點 |

留言、指派、狀態三者可任意組合，至少給一個。

🔴 **被要求「不要看某則留言」時，用 `-ExcludeId`（或建案的 `-ExcludeCommentId`）在印出之前排除**，不要先全部印出再用 grep 過濾——印出來的那一刻就已經看到了（11-24 試跑實例：為了看格式 grep 留言 id，整行印出了要排除的那則）。
不確定要排除哪幾則：先用建案的 `-PeekOnly`，它只列留言 id／時間／人、不印內容。（守衛：無（要不要排除某則留言由派工內容決定，工具只提供能力））

### 讀工單建案

```powershell
& "$wi/fetch-workitem.ps1" -WorkItemUrl 123 -PeekOnly                 # 先看：標題、附件、引用工單、留言 id 清單（不印內容）、描述摘要（不落檔）
& "$wi/fetch-workitem.ps1" -WorkItemUrl 123 -CaseName <案名>          # 建 AI_Service/spec/<案名>/（含 comments.md）
& "$wi/fetch-workitem.ps1" -WorkItemUrl 123 -CaseName <案名> -ExcludeCommentId 4471   # 建案時排除指定留言（可多個）
& "$wi/fetch-workitem.ps1" -WorkItemUrl 123 -CaseName <案名> -Replace # 重抓同一張，覆蓋 spec_00N.md
& "$wi/fetch-related-attachments.ps1" -WorkItemUrl 163 -CaseName <案名> -Name "*.html"
```

- 描述 → `case_spec_content/spec_001.md`（HTML 轉 Markdown，粗體偽標題轉 `##`、☑ 轉 checkbox）；內嵌圖片 → `image1..N.png`；附件 → `attachments/`。
- 留言 → `case_spec_content/comments.md`（舊→新，每則標 id／時間／人；`spec_001.md` 末尾一行指過去）。需求方常在留言回傳答覆檔、補充需求，建案時要讀；
  它是**脈絡**不是需求本文，跟本文衝突的寫進 6.1。`-ExcludeCommentId` 排除的留言只記 id、不擷取內容；`-NoComments` 不抓。
  同一案子已有別張工單的 `comments.md` 時改存 `comments-<工單號>.md`；留言 API 讀不到（例：舊版 Server）時檔內寫明失敗原因，改用 `workitem-ops.ps1 -Action comments` 另外看。
- 引用工單（深度一層）展開到 `related/{工單號}/workitem.md`；有 `ai-case-report.md` 的一併下載（多份取最新）。
  純文字 `#NNN` 可能不是工單（裁定編號、別專案同號）：腳本產 `related/{工單號}/verify.md` 驗證骨架，建案者比對標題與上下文後填結果。
- 引用工單內容是**背景參考**，不是本案需求；與本案衝突時列進「已知未確認」問使用者。
- 建案後依 `hd5-workflow` 判定案件路線。

### 上傳結案報告（`hd5-case-report` 的最後一步）

```powershell
& "$wi/upload-case-report.ps1" -WorkItemUrl 123 -CaseName <案名>           # 預覽（預設）：工單閘結果、目標工單標題、狀態、既有報告版數
& "$wi/upload-case-report.ps1" -WorkItemUrl 123 -CaseName <案名> -Upload   # 使用者同意後才正式上傳（-CasePath 由 -CaseName 推；工單閘沒過會擋）
```

- 上傳前過工單閘（第五節，跟改待驗收同一套）；沒有案子且使用者同意時用 `-SkipAcceptanceGate "<理由>"`。

- 檔名固定 `ai-case-report.md`；上傳前檢查長度、`{{…}}` 佔位符、第 1／2／3／5／6 節、commit 列，不合格就停（`-Force` 照傳）。
- 附件只能新增不能刪除：重傳＝新版（引用端取最新），不要改檔名。只新增附件，不改工單其他欄位。
- 使用者說「先不要上傳」就停在本地，回報「只產本地、未上傳」。

## 七、標準流程（改待驗收）

1. `show`：確認工單標題、目前狀態、上層鏈是你要改的那幾張。
2. `states`：拿到正確的狀態名（各型別狀態集不同，上層工單型別不同時分開下）。
3. 留言稿寫成檔案給使用者看過（白話、列出全部 `未驗證` 項目與需要的資料）。
4. `update … -CasePath … -WhatIfOnly` 預覽（含工單閘結果）→ 使用者確認 → 拿掉 `-WhatIfOnly` 執行。
5. 回報：每張工單的留言 id、狀態、指派、連結（腳本會印）。每一條主張都對得上腳本輸出，沒跑到的就說沒跑。

## 八、常見錯誤

| 症狀 | 處理 |
|---|---|
| 「本專案沒有設定 Azure DevOps」 | `.claude/workflow.json` 的 `tracker.type` 不是 `azure-devops`。問使用者這個專案是否走工單系統；要用就改 type、填 url |
| 「只給工單號碼時需要專案網址」 | 給完整工單網址，或設 `-ProjectUrl`／`AZURE_DEVOPS_PROJECT_URL`／`tracker.url` |
| 「找不到功能地圖檢查工具 … fail closed」 | HD5 工具沒裝或 `paths.tools` 寫錯；用 `-ToolsDir` 指到含 `_verify-map-lib.ps1` 的資料夾 |
| 401 | PAT 過期／權限不足，或 Windows 帳號對該專案沒權限。先 `whoami` |
| 「找不到 Azure DevOps PAT（雲端…）」 | 雲端或非 Windows 沒有整合驗證，照訊息設 PAT |
| 403 | 登得進但沒有這個動作的權限（改狀態／指派要專案 Contributor） |
| 404 | 工單號、organization／collection 或 project 有誤；留言 API 一定要帶 project |
| 「型別 X 沒有狀態 Y」 | 用 `states` 看允許值 |
| 中文變亂碼／語法錯誤 | 腳本少了 BOM；用 `[IO.File]::WriteAllText($p, $c, (New-Object Text.UTF8Encoding($true)))` 補回 |
| 想要驗憑證（雲端） | 加 `-StrictCertificate`（預設不驗，為自架 Server） |

## 九、維護

- 改任何腳本後跑兩支測試，**pwsh 7 與 Windows PowerShell 5.1 都要 `ALL PASSED`**：
  在已開的 pwsh／powershell 用 `& ./tests/workitem-ops.tests.ps1`，或 `pwsh -NoProfile -Command "& './tests/workitem-ops.tests.ps1'; exit $LASTEXITCODE"`（devops-lib 同）。
  不要用 `-File` 另開程序：端點防護（例 COMODO）會把它寫的檔關進隔離區，退回紀錄閘呼叫的 node 看不到測試資料而假失敗（2026-11-25 實測）。
  測試把 `Invoke-RestMethod`／`Invoke-WebRequest` 換成假的，任何未預期的呼叫直接失敗——**測試絕不連真的 Azure DevOps**。
- 相容 5.1：不用 `??`、三元運算子；`-SkipCertificateCheck` 只在 7 才帶，5.1 用 `ServicePointManager` policy 並在 `finally` 還原；5.1 另開 TLS 1.2。
- 認證、工單閘各只有一份（`_auth.ps1`、`_acceptance-gate.ps1`），不要在入口腳本複製。
- 新增動作時維持「讀取不需確認、寫入先預覽」的分界。
- 不准寫死專案網址、組織、人名、信箱、專案資料夾；一律從參數、環境變數或 `.claude/workflow.json` 取。

相關：`hd5-workflow`（收尾順序、對外動作由人決定）、`hd5-review`（獨立驗收結果檔）、`hd5-onsite-gate`（站上關卡報告、第七節）、
`hd5-verify`（功能地圖）、`hd5-case-report`（結案報告內容）。
