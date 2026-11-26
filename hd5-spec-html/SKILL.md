---
name: hd5-spec-html
description: 需求 HTML 摘要＋Open Questions 互動表單的格式與工具鏈：PM 寫題目 JSON → 產生可離線開啟的單檔 HTML（圖片 base64 內嵌）→ 非工程角色在瀏覽器勾選回填、按「儲存答覆」下載 answer 版 → 解析成 Markdown 給 SA／實作讀。pm-expert 要把待澄清問題交給 PO／BA／客戶、主對話要產生／傳送／回收需求問卷、或 sa／實作代理要讀 spec_*.html／spec_*_answer*.html 時使用。選配：上傳 Azure DevOps 工單附件、用 Teams 桌面版傳檔（Windows 才有）。
---

# hd5-spec-html：需求 HTML 文件格式（含圖片內嵌＋Open Questions 表單）

> 適用對象：pm-expert（產出端）、sa-expert／實作代理（讀取端）、主對話（跑工具、傳送與回收）
>
> 本 skill 規範 PM 產出的「需求 HTML 摘要」格式。HTML 是給「非工程角色（PO／BA／業務／客戶）」閱讀並回填澄清問題用的單檔交付物，必須**單一檔案、無外部依賴、無網路請求**。
> 待澄清問題本身怎麼產生（質詢輪、問題清單格式、Q 編號）見 `hd5-grill` 與 `hd5-no-hallucination`。

---

## 一、定位與用途

| 角色 | 對此 HTML 的責任 |
|---|---|
| pm-expert | 產出 `pm/spec_{號碼}.html`（實際上是寫題目 JSON，由主對話跑工具產生，見第八節）；維護圖片 base64 內嵌；維護 Open Questions 區塊 |
| sa-expert | 讀取此 HTML 中的圖文範例（特別是圖片）作為 Gherkin 轉換的依據；不寫入此檔 |
| 實作代理 | 讀取此 HTML 中的圖文範例（介面範例、流程示意）作為實作依據；不寫入此檔 |
| 業務／客戶 | 在瀏覽器中閱讀 → 填寫 Open Questions → 按「儲存答覆」→ 下載 `spec_{號碼}_answer.html` 回傳 |

**重要規則**：

1. HTML 必須能直接以 `file://` 開啟，不可引用任何外部 CSS／JS／圖檔
2. 所有圖片**一律** base64 內嵌（`data:image/{type};base64,...`），即使來源圖檔在同層資料夾也不可用相對路徑
3. HTML 不可包含追蹤碼、外部字型、CDN 資源。專案若有擋外部資源的守衛，指令見本專案 AGENTS.md；
   沒有的話，產出後至少搜尋一次 `src="http`、`href="http`（`Publish-SpecHtml.ps1` 上傳前也會擋）
4. 檔案大小若超過 10 MB 必須在 PM 報告中提示使用者（圖片過多）

---

## 二、檔案命名與位置

`{案子}`＝`AI_Service/spec/<案名>`。

| 用途 | 路徑 | 命名 |
|---|---|---|
| PM 原始 HTML | `{案子}/pm/spec_{號碼}.html` | 與來源 `case_spec_content/spec_{號碼}.md` 同根 |
| PM 題目 JSON | `{案子}/pm/spec_{號碼}.questions.json` | 工具的輸入（第八節） |
| 使用者回填 HTML | （由瀏覽器下載，使用者自行放回） | `spec_{號碼}_answer.html`（建議放回 `case_spec_content/`） |
| 多人多輪答覆 | （由瀏覽器下載） | `spec_{號碼}_answer_{受訪者代號}.html` 或 `spec_{號碼}_answer_{YYYYMMDD}.html` |

---

## 三、圖片 base64 內嵌流程（PM 必做；用工具時自動完成）

### 3.1 來源圖檔掃描

1. 讀取 `case_spec_content/spec_{號碼}.md`
2. 用 Grep 找出所有 markdown 圖片語法：
   - `![alt](path)`
   - `<img src="path">`
3. 對每個 path 解析絕對路徑（相對於 markdown 檔所在目錄）

### 3.2 Base64 編碼（PowerShell 範例）

```powershell
$bytes = [IO.File]::ReadAllBytes("D:\path\to\image.png")
$base64 = [Convert]::ToBase64String($bytes)
# 輸出時搭配 mime type：data:image/png;base64,$base64
```

對應副檔名 → MIME 對照：

| 副檔名 | MIME |
|---|---|
| .png | image/png |
| .jpg / .jpeg | image/jpeg |
| .gif | image/gif |
| .webp | image/webp |
| .svg | image/svg+xml |
| .bmp | image/bmp |

### 3.3 嵌入到 HTML

```html
<figure class="spec-figure">
  <img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA..." alt="原始 alt 文字" />
  <figcaption>原始 alt 文字（檔名: original.png）</figcaption>
</figure>
```

**若圖檔找不到**：在 HTML 中放置警示區塊，**不可省略**：

```html
<div class="spec-figure missing-image">
  ⚠️ 缺少圖檔：original.png（來源 markdown 有引用但檔案不存在）
</div>
```

並將該項加入 Open Questions 區塊請使用者補檔。

---

## 四、HTML 結構規範

HTML 由四個區塊組成（依序）：

1. `<head>`：標題、內嵌 CSS、內嵌 JS（含 Save 邏輯）
2. `<header class="spec-header">`：需求標題、版本、來源檔案、產生時間
3. `<main class="spec-body">`：需求內文（事件風暴摘要＋業務流程＋圖文範例）
4. `<section class="open-questions">`：Open Questions 表單＋「儲存答覆」按鈕

### 4.1 完整 HTML 範本

（第八節的產生器輸出與本範本同構；手寫時照這份。）

```html
<!DOCTYPE html>
<html lang="zh-TW">
<head>
  <meta charset="UTF-8" />
  <title>需求摘要：{需求名稱}（{spec 號碼}）</title>
  <style>
    :root { --primary: #2c5282; --accent: #d69e2e; --danger: #c53030; --bg: #f7fafc; --border: #e2e8f0; }
    * { box-sizing: border-box; }
    body { font-family: "Segoe UI", "Microsoft JhengHei", sans-serif; max-width: 960px; margin: 0 auto; padding: 24px; color: #2d3748; background: var(--bg); }
    h1, h2, h3 { color: var(--primary); }
    .spec-header { border-bottom: 2px solid var(--primary); padding-bottom: 16px; margin-bottom: 24px; }
    .spec-header .meta { color: #718096; font-size: 0.9em; }
    .spec-body section { background: #fff; padding: 20px; margin-bottom: 16px; border-radius: 6px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
    .spec-figure { margin: 16px 0; text-align: center; }
    .spec-figure img { max-width: 100%; border: 1px solid var(--border); border-radius: 4px; }
    .spec-figure figcaption { font-size: 0.85em; color: #718096; margin-top: 6px; }
    .spec-figure.missing-image { background: #fff5f5; color: var(--danger); padding: 12px; border: 1px dashed var(--danger); border-radius: 4px; }
    pre, code { background: #edf2f7; padding: 2px 6px; border-radius: 3px; font-family: "Cascadia Code", Consolas, monospace; }
    pre { padding: 12px; overflow-x: auto; }
    table { border-collapse: collapse; width: 100%; margin: 12px 0; }
    th, td { border: 1px solid var(--border); padding: 8px; text-align: left; }
    th { background: #edf2f7; }

    .open-questions { background: #fffbeb; border: 2px solid var(--accent); padding: 24px; border-radius: 6px; margin-top: 32px; }
    .open-questions h2 { color: var(--accent); margin-top: 0; }
    .open-question { background: #fff; padding: 16px; margin-bottom: 16px; border-radius: 4px; border: 1px solid var(--border); }
    .open-question .q-title { font-weight: bold; margin-bottom: 8px; }
    .open-question .q-context { font-size: 0.9em; color: #718096; margin-bottom: 12px; }
    .open-question .options label { display: block; padding: 4px 0; cursor: pointer; }
    .open-question textarea { width: 100%; min-height: 60px; padding: 8px; border: 1px solid var(--border); border-radius: 4px; font-family: inherit; margin-top: 8px; resize: vertical; }
    .open-question.answered .options label { cursor: default; color: #a0aec0; }
    .open-question.answered .selected-option { color: var(--primary); font-weight: bold; }

    .save-bar { position: sticky; bottom: 0; background: #fff; padding: 16px; border-top: 2px solid var(--primary); margin: 24px -24px -24px; text-align: center; }
    .save-bar button { background: var(--primary); color: #fff; padding: 12px 32px; border: none; border-radius: 4px; font-size: 16px; cursor: pointer; }
    .save-bar button:hover { background: #2a4a7c; }
    .answered-banner { background: #c6f6d5; color: #22543d; padding: 12px; border-radius: 4px; margin-bottom: 16px; text-align: center; font-weight: bold; }
    .answered-banner + .save-bar { display: none; }
  </style>
</head>
<body data-spec-id="{spec 號碼}" data-source="{case_spec_content/spec_xxx.md 相對路徑}">

  <header class="spec-header">
    <h1>需求摘要：{需求名稱}</h1>
    <p class="meta">
      Spec ID：{spec 號碼}　|　
      來源文件：<code>{case_spec_content/spec_xxx.md}</code>　|　
      產生時間：{ISO 8601 時間戳}
    </p>
  </header>

  <main class="spec-body">

    <section>
      <h2>一、需求概要</h2>
      <p>{1-3 段業務目的、角色、價值描述}</p>
    </section>

    <section>
      <h2>二、業務流程</h2>
      <ol>
        <li>{流程步驟一}</li>
        <li>{流程步驟二}</li>
        <!-- ... -->
      </ol>
    </section>

    <section>
      <h2>三、欄位 / 規則對照</h2>
      <table>
        <thead><tr><th>欄位</th><th>來源</th><th>計算規則</th></tr></thead>
        <tbody>
          <tr><td>{欄位}</td><td>{來源}</td><td>{規則}</td></tr>
        </tbody>
      </table>
    </section>

    <section>
      <h2>四、圖文範例</h2>
      <figure class="spec-figure">
        <img src="data:image/png;base64,...." alt="範例 1" />
        <figcaption>範例 1（檔名: example1.png）</figcaption>
      </figure>
    </section>

  </main>

  <section class="open-questions">
    <h2>五、Open Questions（請填寫後儲存）</h2>
    <p>以下項目於 PM 分析時尚無明確答案，請依您的判斷選擇或補充說明，完成後按底部「儲存答覆」下載結果。</p>

    <div class="open-question" data-qid="q1">
      <div class="q-title">Q1. {問題描述}</div>
      <div class="q-context">背景：{為什麼問這題、影響哪段流程}</div>
      <div class="options">
        <label><input type="radio" name="q1" value="A" /> A. {選項一說明}</label>
        <label><input type="radio" name="q1" value="B" /> B. {選項二說明}</label>
        <label><input type="radio" name="q1" value="C" /> C. {選項三說明}</label>
        <label><input type="radio" name="q1" value="OTHER" /> 其他（請於下方說明）</label>
      </div>
      <textarea name="q1_note" placeholder="補充說明（必要時填寫）"></textarea>
    </div>

    <!-- 視需要重複多個 .open-question -->

    <div class="save-bar">
      <button type="button" id="saveBtn" onclick="saveAnswers()">💾 儲存答覆並下載</button>
    </div>
  </section>

  <script>
    function saveAnswers() {
      const specId = document.body.dataset.specId || 'spec';
      const stamp = new Date().toISOString();
      const questions = document.querySelectorAll('.open-question');
      let unanswered = 0;

      questions.forEach(q => {
        const qid = q.dataset.qid;
        const selected = q.querySelector('input[type=radio]:checked');
        const note = q.querySelector('textarea').value.trim();

        if (!selected && !note) { unanswered++; return; }

        q.classList.add('answered');
        const optionsBox = q.querySelector('.options');
        if (selected) {
          const label = selected.closest('label').textContent.trim();
          optionsBox.innerHTML = '<p class="selected-option">✔ 選擇：' + label + '</p>';
        } else {
          optionsBox.innerHTML = '<p class="selected-option">（未勾選選項）</p>';
        }
        const ta = q.querySelector('textarea');
        if (note) {
          const noteP = document.createElement('p');
          noteP.innerHTML = '<strong>補充：</strong>' + note.replace(/</g, '&lt;').replace(/\n/g, '<br/>');
          ta.replaceWith(noteP);
        } else {
          ta.remove();
        }
      });

      if (unanswered === questions.length) {
        alert('目前尚未填寫任何問題，請至少回答一題後再儲存。');
        return;
      }

      const banner = document.createElement('div');
      banner.className = 'answered-banner';
      banner.textContent = '✅ 已於 ' + stamp + ' 填寫完成（共 ' + (questions.length - unanswered) + ' / ' + questions.length + ' 題）';
      const oq = document.querySelector('.open-questions');
      oq.insertBefore(banner, oq.querySelector('.open-question') || oq.querySelector('.save-bar'));

      const saveBar = document.querySelector('.save-bar');
      if (saveBar) saveBar.remove();

      const html = '<!DOCTYPE html>\n' + document.documentElement.outerHTML;
      const blob = new Blob([html], { type: 'text/html;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = specId + '_answer.html';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    }
  </script>
</body>
</html>
```

### 4.2 模板填寫規則

| 區塊 | 必填？ | 內容來源 |
|---|---|---|
| `<title>` | ✅ | `需求摘要：{需求名稱}（{spec 號碼}）` |
| `data-spec-id` | ✅ | spec 號碼，例 `spec_783` —— Save 下載檔名會用到 |
| `data-source` | ✅ | 來源 md 相對路徑 |
| `.spec-header` 的 meta | ✅ | spec id／來源／產生時間（ISO 8601）|
| 「一、需求概要」 | ✅ | 從 `event-storming-{功能名稱}.md` 的 Feature 描述複製 |
| 「二、業務流程」 | ✅ | 用有序列表呈現 PM Gherkin 的主要 Scenario 流程 |
| 「三、欄位／規則對照」 | 若有欄位規則才放 | 來源 md 中明確列出的欄位、規則 |
| 「四、圖文範例」 | 來源 md 有圖才放 | 圖片 base64 內嵌 |
| 「五、Open Questions」 | 必須存在（即使 0 題） | 直接對應 PM 階段提的問題清單 |

### 4.3 Open Questions 欄位規則

- 每題 **必須**有 3-4 個選項＋1 個「其他（請於下方說明）」＋1 個 textarea
- 選項由 PM 根據需求語境**列出可能合理的答案**（不是腦補規則，是把分歧明確化）
- `data-qid` 使用 `q1`, `q2`, ... 順序編號；後續更新時保持穩定
- 若沒有任何 Open Question，本段顯示一行：「目前無待澄清項目，本份需求視為定稿」並隱藏 Save 按鈕

---

## 五、Answer 版本 HTML 行為

按下「儲存答覆並下載」後：

1. 將每題的 radio 選項與 textarea 內容轉成靜態顯示（`.answered` class）
2. 在 Open Questions 區頂部插入一條 banner（已填寫時間＋題數）
3. 移除 Save 按鈕（避免回填者再儲存又下載）
4. 將整個 `documentElement.outerHTML` 包成 Blob 觸發瀏覽器下載
5. 下載檔名＝`{data-spec-id}_answer.html`

**回填者可重複下載**：每次按下都會基於當下 DOM 狀態重新產生檔案，但若已標記 answered 不會二次轉換 → 一份檔案只代表一次填寫快照。

---

## 六、SA／實作代理讀取此 HTML 的方式

SA 與實作代理並不需要 render HTML，只需把 HTML 當文字檔 Read（或先用 `Read-SpecAnswer.ps1` 轉成 md）：

1. 用 Read 讀取 HTML
2. 用 Grep 找關鍵段落（`<section>`、`figure`、`open-question`）
3. **圖片內容**：base64 圖片無法直接看，但 alt／figcaption 是必須的可讀文字 → 從這兩處掌握圖片語意。若 alt 不足以理解，向使用者要原圖（不要腦補）
4. **answer 版本**：若 `case_spec_content/` 出現 `spec_xxx_answer*.html`，必須讀取並把使用者回答視為「已澄清的需求」，覆蓋原始 Open Questions

---

## 七、產出檢查清單

PM 產出 HTML 後必須自我驗證：

- [ ] 檔案能用瀏覽器直接開啟，無 console error
- [ ] 所有圖片皆 base64 內嵌，無 `src="./..."` 或 `src="http..."`
- [ ] 缺失的圖檔已標記為 `missing-image` 並列入 Open Questions
- [ ] `data-spec-id`、`data-source`、`<title>`、產生時間皆已填寫
- [ ] Open Questions 與 PM 階段的問題清單一致（題號可對應）
- [ ] Save 按鈕點擊後能下載 `{spec_id}_answer.html` 並正確呈現答覆
- [ ] 檔案大小 < 10 MB（超過要在報告中提醒使用者）

---

## 八、工具鏈：產生 → 傳給填答者 → 回收 answer → 解析

> 前七節是「HTML 長什麼樣、Save 怎麼動」的規格；本節把它做成腳本，PM 不再手寫 HTML，改寫一份題目 JSON。
> 產出的 HTML 與第四節範本同構（同 CSS、同 Save 行為），只多了三件事：填答者姓名欄、未作答題目標紅、
> 答案同時寫進 `data-answer`／`data-note` 屬性讓下游不用解析畫面文字。
> **由主對話執行**；pm-expert 只負責寫題目 JSON（與 Open Questions 清單一對一）。

工具在本 skill 的 `scripts/`（裝進專案後是 `.claude/skills/hd5-spec-html/scripts/`；Codex 用 `.agents/skills/hd5-spec-html/scripts/`）。
需要 PowerShell（`pwsh` 7 或 Windows PowerShell 5.1）。

| 檔案 | 用途 | 必要／選配 |
|---|---|---|
| `New-SpecHtml.ps1` | 題目 JSON → `spec_{號碼}.html`（圖片自動 base64、缺圖自動追加一題、0 題＝定稿版） | 必要（通用） |
| `Read-SpecAnswer.ps1` | 回填者存下的 `spec_{號碼}_answer*.html` → Markdown 回覆表（`-Json` 可輸出結構化） | 必要（通用） |
| `Publish-SpecHtml.ps1` | 把 spec／answer HTML 上傳成工單附件，可順帶留言；只新增附件、不改欄位 | **選配**：需要 Azure DevOps |
| `Send-TeamsFile.ps1` | 用你自己的 Teams 桌面版把檔案＋訊息送給指定的人（見第九節） | **選配**：需要 Windows＋已登入的 Teams 桌面版 |
| `_spec-html-lib.ps1` | 共用函式；不可直接執行 | — |
| `sample.questions.json` | 題目 JSON 範例（複製後改） | — |
| `tests/spec-html.tests.ps1` | 離線測試；**改過腳本必跑，最後一行要是 `ALL PASSED`** | — |

**沒有工單系統、不是 Windows、沒有 Teams**：兩支選配工具都不用，改成**人工傳送**——把產生的 HTML 用你們平常的管道
（信件、通訊軟體、共用資料夾）傳給填答者，收到回填檔後照樣放回 `case_spec_content/` 跑 `Read-SpecAnswer.ps1`。流程其他步驟不變。

### 8.1 題目 JSON

```json
{
  "specId": "spec_1432",
  "title": "銷售報表統計幣別",
  "source": "case_spec_content/spec_1432.md",
  "summary": "一、需求概要（純文字，空行分段）",
  "flow": ["步驟一", "步驟二"],
  "rules": [ { "field": "欄位", "source": "來源", "rule": "規則" } ],
  "bodyHtmlFile": "可選：額外 body HTML（內含 <img src=相對路徑> 會被 base64 內嵌）",
  "questions": [
    { "id": "q1", "title": "問題", "context": "為什麼問、影響哪段流程",
      "options": ["A 說明", "B 說明", "C 說明"], "allowOther": true, "multi": false }
  ]
}
```

- `questions[].id` 用 `q1`、`q2`… 與 PM 階段的 Open Questions 清單**同號**；後續更新保持穩定。
- 每題至少 2 個選項（腳本會擋）；選項是「把分歧明確化」，不是腦補規則（`hd5-no-hallucination`）。
- `multi: true`＝複選（checkbox）；`allowOther: false` 才會拿掉「其他」。

### 8.2 標準流程（主對話）

`$T`＝`.claude/skills/hd5-spec-html/scripts`；`{案子}`＝`AI_Service/spec/<案名>`。

```powershell
# 1. 產生（省略 -OutFile 時輸出到 JSON 同目錄 {specId}.html）
& "$T/New-SpecHtml.ps1" -QuestionsFile "{案子}/pm/spec_1432.questions.json" -OutFile "{案子}/pm/spec_1432.html"

# 2. 用瀏覽器開一次確認（第七節檢查清單），再傳給填答者：
#    人工傳送；或（選配）上傳工單附件＋留言——先 -WhatIfOnly 看目標工單對不對
& "$T/Publish-SpecHtml.ps1" -WorkItem 1432 -File "{案子}/pm/spec_1432.html" `
    -Comment "需求摘要與待確認問題已附上，請下載開啟、填寫後按「儲存答覆」，把下載的檔案回傳。" -WhatIfOnly

# 3. （選配）Teams 通知填答者（訊息稿先給使用者看；以你本人名義送出）
& "$T/Send-TeamsFile.ps1" -To <填答者 mail> -Peer <填答者顯示名> -File "{案子}/pm/spec_1432.html" -MessageFile ".\teams.txt"

# 4. 收到回填檔 → 放回 case_spec_content/ → 解析成 md 給 SA／實作
& "$T/Read-SpecAnswer.ps1" -AnswerFile "{案子}/case_spec_content/spec_1432_answer.html" -OutFile "{案子}/case_spec_content/spec_1432_answer.md"

# 5. （選配）回覆版也掛回工單（留紀錄）
& "$T/Publish-SpecHtml.ps1" -WorkItem 1432 -File "{案子}/case_spec_content/spec_1432_answer.html"
```

- `-WorkItem` 可給完整工單網址，或只給號碼；只給號碼時專案網址依序取 `-ProjectUrl` → 環境變數 `AZURE_DEVOPS_PROJECT_URL`
  → 從目前資料夾往上找 `.claude/workflow.json` 的 `tracker.url`。都沒有就停下來，不猜。
- 上傳與留言預設走 **Windows 整合驗證、不需 PAT**（有 PAT 的用 `-Pat` 或 `AZURE_DEVOPS_PAT_WRITE`）；必須用 `&` 在目前 session 執行，若有沙箱要關閉。
  🔴 上傳附件、留言、發 Teams 都是對外動作，照 `hd5-workflow`「對外動作由人決定」：先讓使用者看、同意才做。（守衛：無（是否取得同意要靠人））
- 多人回填：每人各存一份 `_answer_{姓名}.html`（Save 會把填答者姓名寫進檔名），逐一解析後由 PM 合併；衝突寫進「已知未確認」問使用者，**不自行取捨**。
- 回填檔一律先 `Read-SpecAnswer.ps1` 看「作答 N / M」，未作答的題要追問，不能當成默認同意。

## 九、（選配）Teams 桌面版傳檔與訊息（Send-TeamsFile.ps1）

> 只有 **Windows＋已登入的新版 Teams 桌面版** 能用；其他環境腳本會直接停下，請改人工傳送。

沒有 Teams API、不需任何權限或 token：腳本操作**你自己已登入的 Teams 桌面版**，訊息以本人名義出現。
下面每一條規則都是實測踩過的坑：

| 步驟 | 做法 | 為什麼 |
|---|---|---|
| 開聊天 | `msteams://teams.microsoft.com/l/chat/0/0?users=<mail>`，再用 `EnumWindows` 依標題「聊天 \| <對象>」鎖視窗 | 開會時 `MainWindowHandle` 指向會議視窗，所有 UIA 查詢會打錯地方 |
| 前景化 | `AttachThreadInput` → `ShowWindow` → `SetForegroundWindow`，驗 `GetForegroundWindow` 相等 | 單純 `SetForegroundWindow` 會被系統擋 |
| 附檔 | 「附加檔案」鈕走 **ExpandCollapsePattern** → 同一行程內立刻 Invoke「從此裝置上傳」→ `#32770`「開啟」對話框 → 檔名欄（控制項 1148）逐字 `WM_CHAR` → UIA 讀回逐字核對 → Enter | `WM_SETTEXT` 跨行程被 UIPI 擋；`GetWindowText` 讀不到 ComboBoxEx |
| 附件判準 | 輸入區「**移除附件**」鈕數量＝1 | 檔名字串在歷史訊息裡也有，掃全樹恆真（曾因此送出沒附件的訊息、也曾掛兩份） |
| 打字 | `WM_CHAR` 逐字投遞到 `Chrome_WidgetWin_1`，每字前驗前景仍是聊天視窗；打完 `TextPattern` 讀回，去空白後逐字相符才送 | 使用者中途切走，字元會進別人的對話框 |
| 送出 | Button「傳送」或「傳送 (…)」`InvokePattern`；等到訊息元素含「已傳送」 | 按鈕名稱後綴隨 Teams 版本／設定而變；對他人是「已傳送 <內容>」、自己的聊天是「<名字> 已傳送 <內容>」，用包含判斷；大附件會停在「傳送中」數秒 |

規則：
- 🔴 **訊息稿先給使用者看過**（以本人口吻、不寫「AI 代為」、不含機密）；`-Action Inspect` 先看草稿是否為空、附件數是否為 0。（守衛：無（訊息稿是否經使用者看過屬人工審閱））
- 🔴 不要在使用者正在打字、或螢幕鎖定時跑（鎖定時附檔對話框與前景化都會失敗；本腳本不處理鎖定狀態）。（守衛：無（使用者是否正在打字無法偵測））
- 失敗時附件與草稿留在輸入框、不會送出；`-Action Clear` 清草稿、附件請手動移除後重跑。
- 對象用 `-To <mail>`（開聊天）＋`-Peer <顯示名>`（鎖視窗）；mail 從工單系統或公司通訊錄查。
- 實測：附約 10 KB HTML＋約 50 字訊息，從開聊天到「已傳送」約 20 秒。

## 十、維護

- 改 `scripts/` 任一支後必跑 `pwsh -File scripts/tests/spec-html.tests.ps1`（pwsh 7 與 Windows PowerShell 5.1 都要 `ALL PASSED`；
  非 Windows 環境會自動略過 Teams 參數檢查並印出 skip——那是「沒驗到」不是「通過」）。
- Save 行為另有 jsdom 實跑測試 `scripts/tests/save-jsdom.test.cjs`：
  `node scripts/tests/save-jsdom.test.cjs <spec.html> <輸出 answer.html> <jsdom 模組路徑>`（需要一份裝了 jsdom 的 node_modules）。
- 腳本必須 **UTF-8 with BOM**、相容 5.1（不用 `??`、三元運算子）。
- 同一份 skill 若在多個 repo 各裝一份，改規則時各份一起改（或重跑 HD5Skills 的 install 同步）。
