#!/bin/sh
# HD5Skills 密鑰掃描 pre-commit hook（install.ps1 -InstallPreCommit 產生；重跑 install 會覆蓋這個檔，要改請改套件範本）
# commit 前掃「已 stage 的新增行」有沒有私鑰、雲端金鑰、權杖、寫死的密碼；有就擋下這次 commit。
# 確定是測試假值：在那一行加註解 hd5-allow-secret。找不到 node 或工具時只提醒、不擋（工單閘還會再掃一次）。
TOOL="__TOOL__"
if ! command -v node >/dev/null 2>&1; then echo "⚠ HD5 密鑰掃描：找不到 node，這次 commit 沒掃" >&2; exit 0; fi
if [ ! -f "$TOOL" ]; then echo "⚠ HD5 密鑰掃描：找不到 $TOOL，這次 commit 沒掃" >&2; exit 0; fi
node "$TOOL" --staged
