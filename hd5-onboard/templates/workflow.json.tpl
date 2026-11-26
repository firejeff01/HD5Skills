{
  "_說明": "HD5Skills 專案設定。hook（grill-gate、main-edit-guard）、質詢閘、功能地圖檢查都讀這份。install.ps1 先放通用預設，hd5-onboard 掃描後依專案改。欄位：paths.* 相對專案資料夾（.claude 所在那層）；implementers[].extensions 是副檔名；implementers[].pathHints 是路徑片段、任意層從目錄邊界開始比對（例 \"ClientApp/\" 對得到 ClientApp/、DIMP/ClientApp/，\"test/\" 對不到 latest/），比副檔名優先；同一種副檔名兩個代理都會改時（例 .cshtml），放在主要負責的那個、另一個用 pathHints 區分；productCode.extensions 要涵蓋所有 implementers 的副檔名（check-onboard 會擋）；productCode.excludeDirs 預設只比「相對專案資料夾的前綴」（\"scripts/\" 只排除 <專案>/scripts/，不排除 frontend/scripts/），要比任意層明確寫 \"**/\" 開頭（例 \"**/node_modules/\"）；roleHints（選填）＝某些目錄歸非實作代理，形狀 [{ agent, pathHints }]，比對方式同 implementers.pathHints，main-edit-guard 建議派誰時最先比（例 tests/ 歸 qa-expert：主對話改測試檔時建議派 qa-expert），agent 要有 .claude/agents/<agent>.md（check-onboard 會擋）；專案資料夾外面的檔 main-edit-guard 本來就不管。tracker.type＝azure-devops｜none，tracker.url＝專案網址。branches.develop＝開發（整合）分支、branches.workBranchPrefix＝工作分支前綴（例 feature/、project_）：hd5-onboard 一開始就問使用者，空的 check-onboard 會擋；main-edit-guard 只在工作分支上擋、跟 develop 比對案子是否本分支新增。",
  "stack": "generic",
  "paths": {
    "aiService": "AI_Service",
    "tools": "AI_Service/hd5-tools"
  },
  "tracker": {
    "type": "none",
    "url": ""
  },
  "branches": {
    "develop": "",
    "test": "",
    "production": "",
    "workBranchPrefix": ""
  },
  "implementers": [
    {
      "agent": "backend-expert",
      "aliases": [],
      "gateRole": "backend",
      "gateAliases": [],
      "extensions": [
        ".cs",
        ".py",
        ".go",
        ".java",
        ".kt",
        ".rb",
        ".php",
        ".sql"
      ],
      "pathHints": []
    },
    {
      "agent": "frontend-expert",
      "aliases": [],
      "gateRole": "frontend",
      "gateAliases": [],
      "extensions": [
        ".vue",
        ".ts",
        ".tsx",
        ".js",
        ".jsx",
        ".svelte",
        ".css",
        ".scss"
      ],
      "pathHints": [
        "frontend/",
        "web/",
        "ClientApp/",
        "src/components/"
      ]
    }
  ],
  "roleHints": [
    {
      "agent": "qa-expert",
      "pathHints": [
        "tests/",
        "test/",
        "__tests__/"
      ]
    }
  ],
  "productCode": {
    "extensions": [
      ".cs",
      ".py",
      ".go",
      ".java",
      ".kt",
      ".rb",
      ".php",
      ".vue",
      ".ts",
      ".tsx",
      ".js",
      ".jsx",
      ".svelte"
    ],
    "excludeDirs": [
      "AI_Service/",
      ".claude/",
      ".agents/",
      "**/node_modules/",
      "scripts/",
      "tools/"
    ]
  }
}
