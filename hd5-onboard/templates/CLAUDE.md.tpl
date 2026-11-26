@AGENTS.md

# Claude Code 專屬

上面引用的 `AGENTS.md` 是專案規則的唯一主檔（Codex 也讀它）。這裡只放 Claude Code 才有的東西；專案事實改在 AGENTS.md。

## 子代理

{{子代理清單：pm-expert、sa-expert、{{實作代理}}、qa-expert；定義在 .claude/agents/}}

派發 prompt 一定寫：案子路徑 `{{AI_Service}}/spec/<案名>`、完成條件（指令＋期望值）、熔斷（同一指令連紅三次、工具呼叫 100 次就停）。

## Hook（自動執行，`.claude/settings.json` 註冊）

| Hook | 什麼時候 | 擋什麼 |
|---|---|---|
| `{{AI_Service}}/hd5-tools/hooks/grill-gate.ps1` | 派子代理時 | prompt 指到案子時跑質詢閘：沒寫路線、想跳步、小問題缺 SA 分析、高風險缺對抗輪、還有待拍板題、PM 問卷沒回收、沒標功能。放行也回一行「grill-gate 放行：…」，派角色代理後沒看到＝hook 沒載入 |
| `{{AI_Service}}/hd5-tools/hooks/main-edit-guard.ps1` | 主對話 Edit／Write 時 | 有進行中案子時，主對話直接改產品程式（例外：spec_001 寫「主對話直接改：理由（使用者 MM-DD 同意）」） |

## Session

在 `{{專案資料夾}}` 啟動 Claude Code（`.claude/settings.json` 與 `.claude/agents/` 在這裡）。從別的資料夾（例：repo 根）開的 session 沒有專案代理與 hook，事後 `cd` 不會補載——停下來請使用者在這裡重開。
