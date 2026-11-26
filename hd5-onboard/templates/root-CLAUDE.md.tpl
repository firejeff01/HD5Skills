# CLAUDE.md（repo 根）

這個 repo 的主專案在 `{{專案資料夾}}/`。專案規則全部在 **`{{專案資料夾}}/AGENTS.md`**。

- 🔴 **Claude Code 必須在 `{{專案資料夾}}/` 啟動。** 在 repo 根（或其他資料夾）開的 session 讀不到專案的子代理與 hook（質詢閘、主對話改檔守衛），
  而且沒有任何錯誤訊息；事後 `cd {{專案資料夾}}` 也不會補載。發現自己在 repo 根：**立刻停下，請使用者在 `{{專案資料夾}}/` 重開**，不要派代理、不要改產品程式。（守衛：{{守衛：有選配 SessionStart 警告就寫 repo 根 .claude/settings.json 的 SessionStart hook，否則寫 無（session 從哪裡啟動由使用者決定）}}）

{{整個 repo 共用的規則（沒有就刪掉這一行）}}
