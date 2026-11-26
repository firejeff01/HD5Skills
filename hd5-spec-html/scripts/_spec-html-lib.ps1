<#
.SYNOPSIS
  hd5-spec-html 工具鏈的共用函式：Open Questions 互動 HTML 產生、answer 版解析、
  工單附件上傳（選配：需要 Azure DevOps；Windows 整合驗證優先）。

.DESCRIPTION
  由 New-SpecHtml.ps1 / Read-SpecAnswer.ps1 / Publish-SpecHtml.ps1 以 dot-source 載入：
      . (Join-Path $PSScriptRoot '_spec-html-lib.ps1')
  本檔不可直接執行。🔴 不得內嵌 PAT／帳密。相容 Windows PowerShell 5.1 與 7；必須 UTF-8 with BOM。

  HTML 的樣式、結構、Save 行為完全依 hd5-spec-html/SKILL.md 第四、五節；
  這裡只是把「PM 手寫 HTML」變成「PM 寫 JSON 題目，腳本產 HTML」。
#>

# --- 基本 -------------------------------------------------------------------
function ConvertTo-SpecHtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

# 純文字段落 → 段落 HTML（空行分段、單換行 <br/>）
function ConvertTo-SpecParagraphs {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $blocks = ($Text -replace "`r`n", "`n") -split "`n\s*`n"
    $out = foreach ($b in $blocks) { '<p>' + ((ConvertTo-SpecHtmlText $b.Trim()) -replace "`n", '<br/>') + '</p>' }
    return ($out -join "`n")
}

$script:SpecMimeMap = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.webp' = 'image/webp'; '.svg' = 'image/svg+xml'; '.bmp' = 'image/bmp' }

function Get-SpecImageDataUri {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $mime = $script:SpecMimeMap[$ext]
    if (-not $mime) { throw "不支援的圖片格式：$Path（僅 png/jpg/gif/webp/svg/bmp）" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    return "data:$mime;base64," + [Convert]::ToBase64String($bytes)
}

# 把 body HTML 裡 <img src="相對路徑"> 全部換成 base64；找不到的圖改成 missing-image 警示區塊並回傳清單
function ConvertTo-SpecEmbeddedImages {
    param([string]$Html, [string]$BaseDir)
    $missing = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrEmpty($Html)) { return @{ Html = ''; Missing = $missing } }
    $out = [regex]::Replace($Html, '(?i)<img\b([^>]*?)\bsrc="([^"]+)"([^>]*)>', {
        param($m)
        $src = $m.Groups[2].Value
        if ($src -match '^(data:|https?:)') { return $m.Value }
        $p = $src
        if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $BaseDir $src }
        if (-not (Test-Path -LiteralPath $p)) {
            $missing.Add($src)
            return '<div class="spec-figure missing-image">⚠️ 缺少圖檔：' + (ConvertTo-SpecHtmlText $src) + '（來源有引用但檔案不存在）</div>'
        }
        return '<img' + $m.Groups[1].Value + 'src="' + (Get-SpecImageDataUri -Path $p) + '"' + $m.Groups[3].Value + '>'
    })
    return @{ Html = $out; Missing = $missing }
}

# --- 題目 -------------------------------------------------------------------
# 題目 JSON 結構（New-SpecHtml.ps1 -QuestionsFile）：
# {
#   "specId": "spec_1432", "title": "RE 再生能源監控", "source": "case_spec_content/spec_1432.md",
#   "summary": "一、需求概要（純文字，空行分段）", "flow": ["步驟一", "步驟二"],
#   "rules": [ { "field": "欄位", "source": "來源", "rule": "規則" } ],
#   "bodyHtmlFile": "可選：額外 body HTML 檔（圖片相對路徑會被 base64 內嵌）",
#   "questions": [
#     { "id": "q1", "title": "問題", "context": "背景", "options": ["A 說明", "B 說明"], "allowOther": true, "multi": false }
#   ]
# }
function Test-SpecQuestions {
    param($Spec)
    $errors = @()
    if (-not $Spec.specId) { $errors += '缺 specId' }
    if (-not $Spec.title) { $errors += '缺 title' }
    $qs = @($Spec.questions)
    $seen = @{}
    $i = 0
    foreach ($q in $qs) {
        $i++
        if (-not $q.id) { $errors += "第 $i 題缺 id" } elseif ($seen.ContainsKey($q.id)) { $errors += "題號重複：$($q.id)" } else { $seen[$q.id] = 1 }
        if (-not $q.title) { $errors += "第 $i 題缺 title" }
        $opts = @($q.options)
        if ($opts.Count -lt 2) { $errors += "第 $i 題（$($q.id)）選項少於 2 個——選項是把分歧明確化，不是腦補；至少兩個" }
    }
    return $errors
}

function New-SpecQuestionHtml {
    param($Q, [int]$Index)
    $qid = ConvertTo-SpecHtmlText ([string]$Q.id)
    $multi = ($Q.multi -eq $true)
    $type = if ($multi) { 'checkbox' } else { 'radio' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("    <div class=""open-question"" data-qid=""$qid""$(if ($multi) { ' data-multi="1"' })>")
    [void]$sb.AppendLine("      <div class=""q-title"">Q$Index. $(ConvertTo-SpecHtmlText ([string]$Q.title))</div>")
    if ($Q.context) { [void]$sb.AppendLine("      <div class=""q-context"">背景：$(ConvertTo-SpecHtmlText ([string]$Q.context))</div>") }
    [void]$sb.AppendLine('      <div class="options">')
    $letters = 'ABCDEFGHIJKLMNOP'
    $k = 0
    foreach ($o in @($Q.options)) {
        $letter = $letters[$k]; $k++
        [void]$sb.AppendLine("        <label><input type=""$type"" name=""$qid"" value=""$letter"" /> $letter. $(ConvertTo-SpecHtmlText ([string]$o))</label>")
    }
    if ($Q.allowOther -ne $false) {
        [void]$sb.AppendLine("        <label><input type=""$type"" name=""$qid"" value=""OTHER"" /> 其他（請於下方說明）</label>")
    }
    [void]$sb.AppendLine('      </div>')
    [void]$sb.AppendLine("      <textarea name=""${qid}_note"" placeholder=""補充說明（必要時填寫）""></textarea>")
    [void]$sb.AppendLine('    </div>')
    return $sb.ToString()
}

$script:SpecCss = @'
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
    .open-question.unanswered { border-color: var(--danger); }
    .open-question.unanswered .q-title::after { content: "（未作答）"; color: var(--danger); font-weight: normal; margin-left: 8px; }
    .answer-meta { margin: 12px 0; }
    .answer-meta input { width: 100%; padding: 8px; border: 1px solid var(--border); border-radius: 4px; font-family: inherit; }
    .save-bar { position: sticky; bottom: 0; background: #fff; padding: 16px; border-top: 2px solid var(--primary); margin: 24px -24px -24px; text-align: center; }
    .save-bar button { background: var(--primary); color: #fff; padding: 12px 32px; border: none; border-radius: 4px; font-size: 16px; cursor: pointer; }
    .save-bar button:hover { background: #2a4a7c; }
    .save-bar .hint { font-size: 0.85em; color: #718096; margin-top: 8px; }
    .answered-banner { background: #c6f6d5; color: #22543d; padding: 12px; border-radius: 4px; margin-bottom: 16px; text-align: center; font-weight: bold; }
    .answered-banner + .save-bar { display: none; }
'@

# Save 行為依 skill 第五節；比範本多三件事：①受訪者姓名欄一起存進 banner／data-answered-by
# ②未作答的題標成 unanswered（紅框）而不是靜默略過 ③每題答案同時寫成 data-answer／data-note 屬性，
# 讓 Read-SpecAnswer.ps1 不必解析畫面文字。
$script:SpecSaveJs = @'
    function saveAnswers() {
      const specId = document.body.dataset.specId || 'spec';
      const stamp = new Date().toISOString();
      const who = (document.getElementById('answeredBy') || { value: '' }).value.trim();
      const questions = document.querySelectorAll('.open-question');
      let unanswered = 0;

      questions.forEach(q => {
        const selected = Array.from(q.querySelectorAll('input:checked'));
        const ta = q.querySelector('textarea');
        const note = ta ? ta.value.trim() : '';
        if (selected.length === 0 && !note) { unanswered++; q.classList.add('unanswered'); return; }

        q.classList.add('answered');
        q.dataset.answer = selected.map(s => s.value).join(',');
        q.dataset.note = note;
        const optionsBox = q.querySelector('.options');
        if (selected.length > 0) {
          const labels = selected.map(s => s.closest('label').textContent.trim());
          optionsBox.innerHTML = '<p class="selected-option">✔ 選擇：' + labels.map(l => l.replace(/</g, '&lt;')).join('；') + '</p>';
        } else {
          optionsBox.innerHTML = '<p class="selected-option">（未勾選選項）</p>';
        }
        if (ta) {
          if (note) {
            const noteP = document.createElement('p');
            noteP.className = 'answer-note';
            noteP.innerHTML = '<strong>補充：</strong>' + note.replace(/</g, '&lt;').replace(/\n/g, '<br/>');
            ta.replaceWith(noteP);
          } else { ta.remove(); }
        }
      });

      if (questions.length > 0 && unanswered === questions.length) {
        alert('目前尚未填寫任何問題，請至少回答一題後再儲存。');
        questions.forEach(q => q.classList.remove('unanswered'));
        return;
      }

      document.body.dataset.answeredAt = stamp;
      document.body.dataset.answeredBy = who;
      const banner = document.createElement('div');
      banner.className = 'answered-banner';
      banner.textContent = '✅ ' + (who ? who + ' ' : '') + '已於 ' + stamp + ' 填寫完成（共 ' + (questions.length - unanswered) + ' / ' + questions.length + ' 題' + (unanswered ? '，' + unanswered + ' 題未作答' : '') + '）';
      const oq = document.querySelector('.open-questions');
      const meta = oq.querySelector('.answer-meta');
      if (meta) { meta.replaceWith(banner); } else { oq.insertBefore(banner, oq.querySelector('.open-question') || oq.querySelector('.save-bar')); }

      const saveBar = document.querySelector('.save-bar');
      if (saveBar) saveBar.remove();

      const html = '<!DOCTYPE html>\n' + document.documentElement.outerHTML;
      const blob = new Blob([html], { type: 'text/html;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = specId + '_answer' + (who ? '_' + who.replace(/[\\/:*?"<>|\s]+/g, '') : '') + '.html';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    }
'@

function New-SpecHtmlDocument {
    param(
        [Parameter(Mandatory = $true)]$Spec,
        [string]$BaseDir = '.',
        [string]$GeneratedAt
    )
    $errs = Test-SpecQuestions -Spec $Spec
    if ($errs.Count) { throw ("題目 JSON 檢查未通過：`n  - " + ($errs -join "`n  - ")) }
    if (-not $GeneratedAt) { $GeneratedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }
    $specId = ConvertTo-SpecHtmlText ([string]$Spec.specId)
    $title = ConvertTo-SpecHtmlText ([string]$Spec.title)
    $source = ConvertTo-SpecHtmlText ([string]$Spec.source)
    $missingAll = New-Object 'System.Collections.Generic.List[string]'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="zh-TW">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('  <meta charset="UTF-8" />')
    [void]$sb.AppendLine("  <title>需求摘要：$title（$specId）</title>")
    [void]$sb.AppendLine('  <style>')
    [void]$sb.AppendLine($script:SpecCss)
    [void]$sb.AppendLine('  </style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine("<body data-spec-id=""$specId"" data-source=""$source"" data-generated-at=""$GeneratedAt"">")
    [void]$sb.AppendLine('  <header class="spec-header">')
    [void]$sb.AppendLine("    <h1>需求摘要：$title</h1>")
    [void]$sb.AppendLine("    <p class=""meta"">Spec ID：$specId　|　來源文件：<code>$source</code>　|　產生時間：$GeneratedAt</p>")
    [void]$sb.AppendLine('  </header>')
    [void]$sb.AppendLine('  <main class="spec-body">')
    $n = 0
    if ($Spec.summary) {
        $n++
        [void]$sb.AppendLine("    <section><h2>一、需求概要</h2>$(ConvertTo-SpecParagraphs ([string]$Spec.summary))</section>")
    }
    if (@($Spec.flow).Count -gt 0) {
        [void]$sb.AppendLine('    <section><h2>二、業務流程</h2><ol>')
        foreach ($s in @($Spec.flow)) { [void]$sb.AppendLine("      <li>$(ConvertTo-SpecHtmlText ([string]$s))</li>") }
        [void]$sb.AppendLine('    </ol></section>')
    }
    if (@($Spec.rules).Count -gt 0) {
        [void]$sb.AppendLine('    <section><h2>三、欄位 / 規則對照</h2><table><thead><tr><th>欄位</th><th>來源</th><th>計算規則</th></tr></thead><tbody>')
        foreach ($r in @($Spec.rules)) { [void]$sb.AppendLine("      <tr><td>$(ConvertTo-SpecHtmlText ([string]$r.field))</td><td>$(ConvertTo-SpecHtmlText ([string]$r.source))</td><td>$(ConvertTo-SpecHtmlText ([string]$r.rule))</td></tr>") }
        [void]$sb.AppendLine('    </tbody></table></section>')
    }
    if ($Spec.bodyHtmlFile) {
        $bp = $Spec.bodyHtmlFile
        if (-not [IO.Path]::IsPathRooted($bp)) { $bp = Join-Path $BaseDir $bp }
        if (-not (Test-Path -LiteralPath $bp)) { throw "找不到 bodyHtmlFile：$bp" }
        $raw = [IO.File]::ReadAllText($bp, [Text.Encoding]::UTF8)
        $emb = ConvertTo-SpecEmbeddedImages -Html $raw -BaseDir ([IO.Path]::GetDirectoryName($bp))
        foreach ($m in $emb.Missing) { $missingAll.Add($m) }
        [void]$sb.AppendLine('    <section><h2>四、圖文範例</h2>')
        [void]$sb.AppendLine($emb.Html)
        [void]$sb.AppendLine('    </section>')
    }
    [void]$sb.AppendLine('  </main>')

    $qs = @($Spec.questions)
    [void]$sb.AppendLine('  <section class="open-questions">')
    if ($qs.Count -eq 0 -and $missingAll.Count -eq 0) {
        [void]$sb.AppendLine('    <h2>五、Open Questions</h2>')
        [void]$sb.AppendLine('    <p>目前無待澄清項目，本份需求視為定稿。</p>')
    }
    else {
        [void]$sb.AppendLine('    <h2>五、Open Questions（請填寫後儲存）</h2>')
        [void]$sb.AppendLine('    <p>以下項目於 PM 分析時尚無明確答案，請依您的判斷選擇或補充說明，完成後按底部「儲存答覆」下載結果，再把下載的檔案回傳（或直接回覆 Teams／工單）。</p>')
        [void]$sb.AppendLine('    <div class="answer-meta"><label>填答者（選填，會寫進檔名與紀錄）<input type="text" id="answeredBy" placeholder="例：王小明" /></label></div>')
        $i = 0
        foreach ($q in $qs) { $i++; [void]$sb.Append((New-SpecQuestionHtml -Q $q -Index $i)) }
        foreach ($m in $missingAll) {
            $i++
            $mq = [pscustomobject]@{ id = "img$i"; title = "缺少圖檔「$m」，請補檔或說明"; context = '來源文件有引用此圖，但檔案不存在'; options = @('已另外提供檔案', '此圖可略過'); allowOther = $true }
            [void]$sb.Append((New-SpecQuestionHtml -Q $mq -Index $i))
        }
        [void]$sb.AppendLine('    <div class="save-bar">')
        [void]$sb.AppendLine('      <button type="button" id="saveBtn" onclick="saveAnswers()">💾 儲存答覆並下載</button>')
        [void]$sb.AppendLine('      <div class="hint">按下後會下載一份「_answer」檔，未作答的題目會標紅但仍可儲存。</div>')
        [void]$sb.AppendLine('    </div>')
    }
    [void]$sb.AppendLine('  </section>')
    [void]$sb.AppendLine('  <script>')
    [void]$sb.AppendLine($script:SpecSaveJs)
    [void]$sb.AppendLine('  </script>')
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')
    return @{ Html = $sb.ToString(); Missing = $missingAll; QuestionCount = $qs.Count }
}

# --- answer 版解析 ------------------------------------------------------------
# 優先讀 data-answer／data-note（本產生器的 Save 會寫）；沒有就退回解析畫面文字（手寫範本產生的 answer 版）。
function Read-SpecAnswerHtml {
    param([Parameter(Mandatory = $true)][string]$Html)
    $result = [ordered]@{
        SpecId     = $null; AnsweredAt = $null; AnsweredBy = $null; Answers = @()
    }
    if ($Html -match 'data-spec-id="([^"]*)"') { $result.SpecId = [System.Net.WebUtility]::HtmlDecode($Matches[1]) }
    if ($Html -match 'data-answered-at="([^"]*)"') { $result.AnsweredAt = $Matches[1] }
    if ($Html -match 'data-answered-by="([^"]*)"') { $result.AnsweredBy = [System.Net.WebUtility]::HtmlDecode($Matches[1]) }
    if (-not $result.AnsweredAt -and $Html -match '已於\s+([0-9T:\.\-Z+]+)\s+填寫完成') { $result.AnsweredAt = $Matches[1] }

    $blocks = [regex]::Matches($Html, '(?is)<div class="open-question([^"]*)"([^>]*)>(.*?)</div>\s*(?=<div class="open-question|<div class="save-bar|</section>)')
    foreach ($b in $blocks) {
        $classes = $b.Groups[1].Value; $attrs = $b.Groups[2].Value; $inner = $b.Groups[3].Value
        $qid = ''; if ($attrs -match 'data-qid="([^"]*)"') { $qid = $Matches[1] }
        $title = ''; if ($inner -match '(?is)<div class="q-title">(.*?)</div>') { $title = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($Matches[1], '<[^>]+>', ''))).Trim() }
        $answer = $null; $note = $null; $label = $null
        if ($attrs -match 'data-answer="([^"]*)"') { $answer = [System.Net.WebUtility]::HtmlDecode($Matches[1]) }
        if ($attrs -match 'data-note="([^"]*)"') { $note = [System.Net.WebUtility]::HtmlDecode($Matches[1]) }
        if ($inner -match '(?is)<p class="selected-option">(.*?)</p>') { $label = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($Matches[1], '<[^>]+>', ''))).Trim() -replace '^✔\s*選擇：', '' }
        if ($null -eq $note -and $inner -match '(?is)<p class="answer-note"><strong>補充：</strong>(.*?)</p>') { $note = [System.Net.WebUtility]::HtmlDecode(($Matches[1] -replace '<br\s*/?>', "`n")) }
        if ($null -eq $note -and $inner -match '(?is)<p><strong>補充：</strong>(.*?)</p>') { $note = [System.Net.WebUtility]::HtmlDecode(($Matches[1] -replace '<br\s*/?>', "`n")) }
        if ($null -eq $answer -and $label -and $label -ne '（未勾選選項）') { $answer = ($label -split '；' | ForEach-Object { ($_ -replace '^\s*([A-P]|其他)[\.．].*$', '$1').Trim() }) -join ',' }
        $answered = ($classes -match 'answered') -and -not ($classes -match 'unanswered')
        $result.Answers += [pscustomobject]@{ Id = $qid; Title = $title; Answered = $answered; Answer = $answer; AnswerText = $label; Note = $note }
    }
    return [pscustomobject]$result
}

function ConvertTo-SpecAnswerMarkdown {
    param([Parameter(Mandatory = $true)]$Parsed)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Open Questions 回覆｜$($Parsed.SpecId)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- 填答者：$(if ($Parsed.AnsweredBy) { $Parsed.AnsweredBy } else { '（未填）' })")
    [void]$sb.AppendLine("- 填答時間：$(if ($Parsed.AnsweredAt) { $Parsed.AnsweredAt } else { '（無紀錄）' })")
    $done = @($Parsed.Answers | Where-Object { $_.Answered }).Count
    [void]$sb.AppendLine("- 作答：$done / $(@($Parsed.Answers).Count) 題")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| 題號 | 問題 | 選擇 | 補充 |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($a in $Parsed.Answers) {
        $sel = if (-not $a.Answered) { '（未作答）' } elseif ($a.AnswerText) { $a.AnswerText } elseif ($a.Answer) { $a.Answer } else { '（未勾選選項）' }
        $note = if ($a.Note) { ($a.Note -replace "`r?`n", '<br/>') -replace '\|', '＼|' } else { '' }
        [void]$sb.AppendLine("| $($a.Id) | $(($a.Title -replace '\|', '＼|')) | $(($sel -replace '\|', '＼|')) | $note |")
    }
    return $sb.ToString()
}

# --- 工單附件上傳（Windows 整合驗證優先；選配：需要 Azure DevOps） --------------
# 從 $Start 往上找 .claude/workflow.json，回傳 tracker.url（找不到或沒填＝$null）。不寫死任何專案網址。
function Get-SpecTrackerUrl {
    param([string]$Start)
    if ([string]::IsNullOrWhiteSpace($Start)) { return $null }
    $d = $Start
    while ($d) {
        $cfg = $null
        if ((Split-Path $d -Leaf) -eq '.claude' -and (Test-Path -LiteralPath (Join-Path $d 'workflow.json'))) { $cfg = Join-Path $d 'workflow.json' }
        elseif (Test-Path -LiteralPath (Join-Path $d '.claude\workflow.json')) { $cfg = Join-Path $d '.claude\workflow.json' }
        if ($cfg) {
            try { $wf = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $null }
            if ($wf.tracker -and -not [string]::IsNullOrWhiteSpace([string]$wf.tracker.url)) { return ([string]$wf.tracker.url).Trim() }
            return $null
        }
        $p = Split-Path $d -Parent
        if (-not $p -or $p -eq $d) { break }
        $d = $p
    }
    return $null
}

function Resolve-SpecWorkItem {
    param([Parameter(Mandatory = $true)][string]$WorkItem, [string]$ProjectUrl, [string]$ConfigStart)
    $WorkItem = $WorkItem.Trim(); $id = 0; $origin = $null; $collection = $null; $project = $null
    if ($WorkItem -match '^\d+$') {
        $id = [int]$WorkItem
        if ([string]::IsNullOrWhiteSpace($ProjectUrl)) { $ProjectUrl = [Environment]::GetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL') }
        if ([string]::IsNullOrWhiteSpace($ProjectUrl)) { $ProjectUrl = Get-SpecTrackerUrl -Start $ConfigStart }
        if ([string]::IsNullOrWhiteSpace($ProjectUrl)) { throw '只給工單號碼時必須提供 -ProjectUrl（https://host/{collection}/{project}）、設 AZURE_DEVOPS_PROJECT_URL，或在 .claude/workflow.json 填 tracker.url' }
        $u = [Uri]$ProjectUrl.Trim().TrimEnd('/'); $seg = $u.AbsolutePath.Trim('/').Split('/')
        if ($seg.Count -lt 2) { throw "-ProjectUrl 必須含 collection 與 project：$ProjectUrl" }
        $origin = "$($u.Scheme)://$($u.Authority)"; $collection = $seg[0]; $project = [Uri]::UnescapeDataString($seg[1])
    }
    else {
        if ($WorkItem -match '_workitems/edit/(\d+)') { $id = [int]$Matches[1] }
        elseif ($WorkItem -match '[?&]workitem=(\d+)') { $id = [int]$Matches[1] }
        else { throw "無法從網址解析工單編號：$WorkItem" }
        $u = [Uri]$WorkItem; $seg = $u.AbsolutePath.Trim('/').Split('/')
        if ($seg.Count -lt 2 -or $seg[1] -eq '_apis') { throw "工單網址缺少 project 段：$WorkItem" }
        $origin = "$($u.Scheme)://$($u.Authority)"; $collection = $seg[0]; $project = [Uri]::UnescapeDataString($seg[1])
    }
    return [pscustomobject]@{ Id = $id; Origin = $origin; Collection = $collection; Project = $project; ProjectApi = "$origin/$collection/$([Uri]::EscapeDataString($project))/_apis"; WebUrl = "$origin/$collection/$([Uri]::EscapeDataString($project))/_workitems/edit/$id" }
}

function New-SpecAuth {
    param([string]$Pat, [string]$ScriptRoot)
    if (-not [string]::IsNullOrWhiteSpace($Pat)) { return @{ Mode = 'PAT'; Source = '-Pat'; Headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($Pat.Trim())")) } } }
    foreach ($c in @(@{ Env = 'AZURE_DEVOPS_PAT_WRITE'; File = 'pat.write.local.txt' }, @{ Env = 'AZURE_DEVOPS_PAT'; File = 'pat.local.txt' })) {
        $v = [Environment]::GetEnvironmentVariable($c.Env)
        if ([string]::IsNullOrWhiteSpace($v) -and $ScriptRoot) {
            foreach ($dir in @($ScriptRoot, (Join-Path $ScriptRoot '..'))) {
                $f = Join-Path $dir $c.File
                if (Test-Path -LiteralPath $f) { $line = Get-Content -LiteralPath $f | Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') } | Select-Object -First 1; if ($line) { $v = $line } ; break }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($v)) { return @{ Mode = 'PAT'; Source = $c.Env; Headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($v.Trim())")) } } }
    }
    return @{ Mode = 'Windows'; Source = 'Windows 整合驗證（目前登入帳號）'; Headers = @{} }
}

function Invoke-SpecApi {
    param([hashtable]$Auth, [string]$Uri, [string]$Method = 'Get', $Body, [string]$ContentType)
    $p = @{ Uri = $Uri; Method = $Method; ErrorAction = 'Stop' }
    if ($Auth.Mode -eq 'Windows') { $p.UseDefaultCredentials = $true } else { $p.Headers = $Auth.Headers }
    if ($null -ne $Body) { $p.Body = $Body; if ($ContentType) { $p.ContentType = $ContentType } }
    try { return Invoke-RestMethod @p }
    catch {
        $status = 0; try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        throw "HTTP $status（$($Auth.Source)）：$($_.Exception.Message)`n  URI：$Uri"
    }
}

function Get-SpecWorkItem {
    param([hashtable]$Auth, $Target)
    return Invoke-SpecApi -Auth $Auth -Uri "$($Target.ProjectApi)/wit/workitems/$($Target.Id)?`$expand=relations&api-version=6.0"
}

# POST 附件 → PATCH relations 掛到工單；回傳附件 url。DevOps 附件只增不刪，重傳＝多一份同名。
function Add-SpecAttachment {
    param([hashtable]$Auth, $Target, [string]$Path, [string]$Comment)
    $name = [IO.Path]::GetFileName($Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $up = Invoke-SpecApi -Auth $Auth -Uri "$($Target.ProjectApi)/wit/attachments?fileName=$([Uri]::EscapeDataString($name))&api-version=6.0" -Method Post -Body $bytes -ContentType 'application/octet-stream'
    $patch = '[' + (@{ op = 'add'; path = '/relations/-'; value = @{ rel = 'AttachedFile'; url = $up.url; attributes = @{ comment = $Comment } } } | ConvertTo-Json -Compress -Depth 6) + ']'
    Invoke-SpecApi -Auth $Auth -Uri "$($Target.ProjectApi)/wit/workitems/$($Target.Id)?api-version=6.0" -Method Patch -Body ([Text.Encoding]::UTF8.GetBytes($patch)) -ContentType 'application/json-patch+json; charset=utf-8' | Out-Null
    return $up.url
}

function Add-SpecComment {
    param([hashtable]$Auth, $Target, [string]$Html)
    $body = [Text.Encoding]::UTF8.GetBytes((@{ text = $Html } | ConvertTo-Json -Compress -Depth 3))
    return Invoke-SpecApi -Auth $Auth -Uri "$($Target.ProjectApi)/wit/workItems/$($Target.Id)/comments?api-version=6.0-preview.3" -Method Post -Body $body -ContentType 'application/json; charset=utf-8'
}
