# _comments.ps1 — 工單留言的篩選與輸出（純函式，不連網；workitem-ops.ps1 與 fetch-workitem.ps1 共用）
#
# 2026-11-24（試跑 O-02／O-03）：
#   - 讀留言要能「只讀指定的」或「排除指定的」——brief 要求排除某則留言時，工具沒有對應能力，只能先全部印出再事後過濾，等於已經看到了。
#     ⇒ -Id／-ExcludeId 在印出之前就篩掉；被排除的留言連摘要都不印，只印 id。
#   - 建案要把留言一起存成 case_spec_content/comments.md（需求方常在留言回傳 answer 檔、補充需求）。

# 留言 HTML → 單行純文字
function ConvertTo-HD5CommentText {
    param([string]$Html)
    $t = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace([string]$Html, '<[^>]+>', ' ')))
    return ($t -replace '\s+', ' ').Trim()
}

# 依 -Id（只留這些）與 -ExcludeId（拿掉這些）篩留言；兩者都給時先留 -Id 再排除 -ExcludeId。
# 回傳 [pscustomobject]@{ Comments; ExcludedIds; MissingIds }（MissingIds＝-Id 指定了但工單上沒有的）
function Select-HD5Comments {
    param([object[]]$Comments, [int[]]$Id, [int[]]$ExcludeId)
    $all = @($Comments | Where-Object { $null -ne $_ })
    $keep = $all
    if ($Id -and $Id.Count) { $keep = @($keep | Where-Object { $Id -contains [int]$_.id }) }
    $excluded = @()
    if ($ExcludeId -and $ExcludeId.Count) {
        $excluded = @($keep | Where-Object { $ExcludeId -contains [int]$_.id } | ForEach-Object { [int]$_.id })
        $keep = @($keep | Where-Object { $ExcludeId -notcontains [int]$_.id })
    }
    $missing = @()
    if ($Id -and $Id.Count) { $have = @($all | ForEach-Object { [int]$_.id }); $missing = @($Id | Where-Object { $have -notcontains $_ }) }
    return [pscustomobject]@{ Comments = $keep; ExcludedIds = $excluded; MissingIds = $missing }
}

# 單則留言的一行摘要（workitem-ops -Action comments 用）
function Format-HD5CommentLine {
    param($Comment)
    return "[$($Comment.createdDate)] $($Comment.createdBy.displayName)（id $($Comment.id)）：$(ConvertTo-HD5CommentText $Comment.text)"
}

# 建案用的 comments.md（舊→新；被排除的只列 id，不留內容）
function Format-HD5CommentsMarkdown {
    param([object[]]$Comments, [int]$WorkItemId, [string]$WorkItemUrl, [int[]]$ExcludedIds, [string]$FetchError)
    $L = @("# 工單 #$WorkItemId 留言", '', "> 來源工單：[#$WorkItemId]($WorkItemUrl)　擷取：$((Get-Date).ToString('yyyy-MM-dd HH:mm'))", '> 留言是**脈絡**（需求方的補充、答覆檔通知、討論），不是需求本文；跟 spec_001.md 衝突的寫進 6.1 intake 補註。')
    if ($ExcludedIds -and $ExcludedIds.Count) { $L += "> 已依指示排除留言 id：$(($ExcludedIds | Sort-Object) -join '、')（內容未擷取）" }
    $L += ''
    if ($FetchError) { $L += "⚠ 留言讀取失敗：$FetchError（請用 workitem-ops.ps1 -Action comments 另外看）"; return ($L -join "`n") + "`n" }
    $list = @($Comments | Sort-Object { [datetime]$_.createdDate })
    if (-not $list.Count) { $L += '（沒有留言）'; return ($L -join "`n") + "`n" }
    foreach ($c in $list) {
        $L += "## id $($c.id)｜$($c.createdDate)｜$($c.createdBy.displayName)"
        $L += ''
        $L += (ConvertFrom-HD5CommentHtmlBlock $c.text)
        $L += ''
    }
    return ($L -join "`n") + "`n"
}

# 多行保留：<br>、</p>、</div>、</li> 轉換行，其他標籤去掉
function ConvertFrom-HD5CommentHtmlBlock {
    param([string]$Html)
    $t = [regex]::Replace([string]$Html, '(?i)<br\s*/?>|</p>|</div>|</li>', "`n")
    $t = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($t, '<[^>]+>', '')))
    $lines = @($t -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
    return (($lines -join "`n") -replace "`n{3,}", "`n`n").Trim()
}
