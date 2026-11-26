# AGENTS.md — {{專案名稱}}

> 由 HD5Skills／hd5-onboard 產生（{{日期}}），Claude（經 CLAUDE.md 的 `@AGENTS.md`）與 Codex 共用這一份。
> 流程規則來自 `hd5-workflow` skill；本檔只寫**這個專案**的事實。改之前先問「這是流程規則還是專案事實」。
> 🟨 待補＝掃描推不出來、使用者還沒回答的地方，之後補上就刪掉標記。

## 專案概觀

{{一段話：這個系統做什麼、給誰用、主要模組}}

## 技術架構

| 層 | 技術 | 位置 |
|---|---|---|
{{技術架構表：後端／前端／資料庫／測試／建置，每列寫技術與目錄}}

- 實作代理與它們管哪些檔：`.claude/workflow.json`（{{實作代理摘要，例：backend-expert 管 .cs；frontend-expert 管 ClientApp/ 底下}}）
- 產品程式範圍：{{productCode 摘要}}

## 建置、測試與執行指令

| 用途 | 指令 | 什麼時候跑 | 注意 |
|---|---|---|---|
{{指令表：建置、單元測試、整合測試、前端關卡、本機執行；每列寫清楚注意事項（例：會不會寫到共用資料）}}

- 🔴 **先確認測試真的有跑到**：filter／選擇器對不到測試時不會報錯，只會安靜少跑。用實跑結果的數量對上磁碟上的測試數。（守衛：無（少收不報錯是測試工具的行為；專案做了母體檢查腳本就改標那支））

## 🔴 這個環境會騙你的地方（守衛：無（每列的擋法欄各自標守衛））

只列「訊號本身不可信」的情況。同一個錯第二次發生，就做成會擋人的檢查（`hd5-workflow`「錯誤升級階梯」）。

| 你看到 | 實際是 | 擋法 |
|---|---|---|
{{陷阱表：掃描找到的候選＋使用者確認的已知坑；擋法寫守衛名稱或「無」}}

## 本專案特有的反直覺之處

{{照常識做會錯的地方：例如 ORM 預設行為、名字像防護其實不做事的函式、只改一邊會失效的成對規則；沒有就寫「目前沒有已知項目（🟨 待補）」}}

## 分支、部署與工單

- 分支：{{開發／測試／正式分支；從哪裡開工作分支}}
- 部署：{{測試環境怎麼上、正式環境誰上}}
- 工單系統：{{Azure DevOps（專案網址）或「沒有工單系統：需求以文字建案」}}

## AI 協作流程

照 `hd5-workflow` skill：建案判路線（四角色／PM 端已完成／小問題）寫進 `{{AI_Service}}/spec/<案名>/case_spec_content/spec_001.md`，
照路線派 pm-expert → sa-expert → qa-expert（測試計畫＋Red）→ {{實作代理}}（Green）→ qa-expert（驗證與報告）；主對話不直接改產品程式。

- 關卡工具：`{{AI_Service}}/hd5-tools/`（質詢閘 `validate-grill-gate.ps1`、功能地圖 `verify-map-check.ps1`、守衛對帳 `check-guard-refs.mjs`）
- Codex 沒有 hook：派發前**一定**先跑質詢閘（每個角色一行，照 workflow.json 的 implementers 逐一列出）：
{{質詢閘指令表：每列 `pwsh -File {{AI_Service}}/hd5-tools/validate-grill-gate.ps1 -Role <sa、qa、各實作代理的 gateRole> -CasePath {{AI_Service}}/spec/<案名>`，並寫這個角色派給哪個代理}}
- Codex 擔任 pm／sa／實作／qa 角色時：完整讀 `.claude/agents/<角色>.md` 的本文照做（忽略 frontmatter 的 tools／model，那是 Claude 子代理設定）；
  專案自有、放在 `.claude/skills/<名>/` 的 skill，Codex 直接讀該 `SKILL.md`（`.agents/skills/` 只裝了 HD5Skills 的流程 skill）
- 功能地圖：`{{AI_Service}}/verify/`（每個功能一檔：怎麼到達、怎麼操作、地雷）；開工先跑 `verify-map-check.ps1`
- 規格正本：{{專案固定的規格位置（例 `sa/<上下文>/*.feature` 編進測試專案）＋案子 SA 產物由誰、何時併回；沒有固定位置就寫「規格只留在案子資料夾」}}

## 人工閘門（一定要人決定）

{{列出：push 哪些分支要先問、部署、寫共用資料、對外通知、改工單狀態…；AI 不代打密碼、不設存取權杖}}
