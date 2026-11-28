// check-onboard.mjs — hd5-onboard 產物檢查（會擋人的關卡，2026-11-23）
//
// 檢查一個專案資料夾的導入結果：
//   AGENTS.md   必備小節齊全、沒有殘留 {{佔位符}}；🟨 待補只警告
//   CLAUDE.md   第一個非空行是 @AGENTS.md（主檔是 AGENTS.md，Claude 經引用讀到）
//   .claude/workflow.json   可解析；每個 implementer 的代理檔存在、frontmatter name 一致；paths.tools 存在且有質詢閘
//   .claude/agents          pm／sa／qa-expert 都在；實作代理的「本專案技術架構重點」不能還是範本預設字
//   .claude/settings.json   兩支 hook 都註冊、指到的檔存在
//   skills                  .claude/skills/hd5-workflow 與 .agents/skills/hd5-workflow（Codex）都在
//   功能地圖                <AI_Service>/verify 存在（內容合不合格交給 verify-map-check，這裡只警告）
//   既有規則去向表          有 onboard/backup/，或 onboard/architecture.md「既有規則清單」有表格列 ⇒ 要有 rules-migration.md，列數不少於清單
//   導入問答                onboard/onboard-grill.md 還有「待問」⇒ 擋；🟨 待補只警告
//   roleHints               每筆有 agent＋pathHints，.claude/agents/<agent>.md 存在
//   佔位符                  反引號行內碼與程式碼區塊內的 {{…}} 不算（docker --format、Go template）
//   .gitignore              導入產物（AGENTS.md、CLAUDE.md、.claude/workflow.json、settings.json、agents/*.md、兩份 hd5-workflow SKILL.md、
//                           paths.tools 底下的工具）被 git 忽略 ⇒ 擋，點名哪個 .gitignore 第幾行；已追蹤的檔不算；不是 git repo 就跳過
//   Codex 角色              AGENTS.md 沒提到 .claude/agents（Codex 擔任角色時讀代理本文）⇒ 警告
// 用法：node check-onboard.mjs --project <專案資料夾> [--json]；不合格 exit 1
//       node check-onboard.mjs --selftest
import { readFileSync, existsSync, readdirSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { join, dirname, resolve, posix } from 'node:path'
import { execFileSync, spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

export const REQUIRED_SECTIONS = ['專案概觀', '技術架構', '建置、測試與執行指令', '這個環境會騙你的地方', '本專案特有的反直覺之處', '分支、部署與工單', 'AI 協作流程', '人工閘門']
const TEMPLATE_STACK_MARK = '初始化腳本會在這裡放技術架構的重點規則'

// 沒填的 {{佔位符}}：反引號行內碼與 ```／~~~ 程式碼區塊內的 {{…}} 是合法內容（docker --format "{{.Name}}"、Go template、Handlebars），不算（11-23 導入實測）
// 但範本自己的佔位符（例 `{{AI_Service}}/verify/` 本來就寫在反引號裡）不論在哪都算沒填
const TEMPLATE_PLACEHOLDERS = (() => {
  const s = new Set()
  for (const f of ['AGENTS.md.tpl', 'CLAUDE.md.tpl']) {
    try { for (const m of readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'templates', f), 'utf8').matchAll(/\{\{[^}]+\}\}/g)) s.add(m[0]) } catch { }
  }
  return s
})()
export function placeholders(text) {
  const src = String(text ?? '')
  const out = [...TEMPLATE_PLACEHOLDERS].filter(p => src.includes(p)); let fence = false
  for (const l of src.replace(/\r\n/g, '\n').split('\n')) {
    if (/^\s*(```|~~~)/.test(l)) { fence = !fence; continue }
    if (fence) continue
    const t = l.replace(/(`+)(.+?)\1/g, '')
    for (const m of t.matchAll(/\{\{[^}]+\}\}/g)) out.push(m[0])
  }
  return [...new Set(out)]
}
// 某個標題（任一層 #）底下的內文，到下一個同層或更高層標題為止；沒有這個標題回 null
export function sectionBody(text, title) {
  let lvl = 0; const body = []
  for (const l of String(text ?? '').replace(/\r\n/g, '\n').split('\n')) {
    const h = l.match(/^(#{1,6})\s+(.+)$/)
    if (lvl) { if (h && h[1].length <= lvl) break; body.push(l) }
    else if (h && h[2].includes(title)) lvl = h[1].length
  }
  return lvl ? body.join('\n') : null
}
// 表格資料列（每個表格去掉表頭與分隔列），每列回傳儲存格陣列
export function tableRows(text) {
  const rows = []; let inTable = false
  for (const l of String(text ?? '').replace(/\r\n/g, '\n').split('\n')) {
    if (!/^\s*\|/.test(l)) { inTable = false; continue }
    if (/^\s*\|[\s:|-]+\|?\s*$/.test(l)) continue
    if (!inTable) { inTable = true; continue }   // 表頭
    rows.push(l.trim().replace(/^\||\|$/g, '').split('|').map(c => c.trim()))
  }
  return rows
}
function findDirAnyLevel(root, rel, depth = 0) {
  if (depth > 6) return false
  let es; try { es = readdirSync(root, { withFileTypes: true }) } catch { return false }
  for (const e of es) {
    if (!e.isDirectory() || /^(node_modules|\.git|bin|obj|dist)$/.test(e.name)) continue
    const p = join(root, e.name)
    if (existsSync(join(p, rel)) || findDirAnyLevel(p, rel, depth + 1)) return true
  }
  return false
}

// git 會忽略的檔（rels 相對 proj，/ 分隔）：回 [{ path, src, line, pattern }]；不是 git repo 回 null。
// 已追蹤（在 index）的檔 check-ignore 本來就不報；「!」例外規則命中＝沒被忽略
export function gitIgnored(proj, rels) {
  try { execFileSync('git', ['-C', proj, 'rev-parse', '--is-inside-work-tree'], { stdio: ['ignore', 'pipe', 'ignore'] }) } catch { return null }
  if (!rels.length) return []
  const r = spawnSync('git', ['-C', proj, 'check-ignore', '-v', '-z', '--stdin'], { input: rels.join('\0') + '\0', encoding: 'utf8' })
  if (r.status !== 0 && r.status !== 1) return []   // 128＝git 自己出錯（例 路徑在 repo 外）：不擋
  let prefix = ''; try { prefix = execFileSync('git', ['-C', proj, 'rev-parse', '--show-prefix'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() } catch { }
  const f = String(r.stdout || '').split('\0'), out = []
  for (let i = 0; i + 3 < f.length; i += 4) {
    const [src0, line, pattern, path] = f.slice(i, i + 4)
    if (!path || pattern.startsWith('!')) continue
    // src 相對 repo 根（.git/info/exclude、全域 excludesFile 例外）；例外規則（!路徑）要寫成相對那份 .gitignore 所在資料夾
    const src = src0.replace(/\\/g, '/'), full = prefix + path
    const sd = posix.dirname(src), plain = /(^|\/)\.gitignore$/.test(src) && !/^([A-Za-z]:|\/)/.test(src)
    const neg = plain && sd !== '.' ? posix.relative(sd, full) : full
    out.push({ path, src: plain && sd === '.' ? 'repo 根的 .gitignore' : src, line, pattern, neg })
  }
  return out
}
// 導入產物清單（相對 proj）：入口檔、設定、代理、兩份流程 SKILL.md、paths.tools 底下的工具（腳本檔；PAT 之類本來就該忽略的 .txt 不算）
function onboardArtifacts(proj, tools) {
  const rels = ['AGENTS.md', 'CLAUDE.md', '.claude/workflow.json', '.claude/settings.json', '.claude/skills/hd5-workflow/SKILL.md', '.agents/skills/hd5-workflow/SKILL.md']
  try { for (const f of readdirSync(join(proj, '.claude', 'agents'))) if (f.endsWith('.md')) rels.push(`.claude/agents/${f}`) } catch { }
  if (tools) {
    const td = String(tools).replace(/\\/g, '/').replace(/\/+$/, ''); let n = 0
    const walk = (d, rel, depth) => {
      let es; try { es = readdirSync(d, { withFileTypes: true }) } catch { return }
      for (const e of es) {
        if (n > 500 || depth > 6) return
        if (e.isDirectory()) { if (!/^(node_modules|\.git|bin|obj)$/.test(e.name)) walk(join(d, e.name), `${rel}/${e.name}`, depth + 1) }
        else if (/\.(ps1|psm1|mjs|cjs|js|sh)$/i.test(e.name)) { rels.push(`${rel}/${e.name}`); n++ }
      }
    }
    walk(join(proj, td), td, 0)
    if (!n) rels.push(`${td}/validate-grill-gate.ps1`)
  }
  return rels
}

export function check(proj) {
  const errors = [], warns = []
  const rd = p => { try { return readFileSync(join(proj, p), 'utf8').replace(/^﻿/, '') } catch { return null } }
  // AGENTS.md
  const ag = rd('AGENTS.md')
  if (ag === null) errors.push('缺 AGENTS.md（Claude 與 Codex 共用的主檔）')
  else {
    const heads = [...ag.matchAll(/^##\s+(.+)$/gm)].map(m => m[1].replace(/🔴|🟨/g, '').trim())
    for (const s of REQUIRED_SECTIONS) if (!heads.some(h => h.includes(s))) errors.push(`AGENTS.md 缺小節「${s}」`)
    const ph = placeholders(ag)
    if (ph.length) errors.push(`AGENTS.md 還有沒填的佔位符：${ph.slice(0, 6).join('、')}${ph.length > 6 ? '…' : ''}`)
    const todo = (ag.match(/🟨\s*待補/g) || []).length
    if (todo) warns.push(`AGENTS.md 有 ${todo} 處 🟨 待補（掃描推不出來、使用者還沒回答）`)
    // 資安（2026-11-28）：要寫相依套件弱點掃描怎麼跑（獨立驗收委託附結果）；只警告
    if (!/相依套件弱點掃描/.test(ag)) warns.push('AGENTS.md 沒寫「相依套件弱點掃描」：依套件管理工具寫指令（npm audit、dotnet list package --vulnerable、pip-audit…），真的沒有第三方套件寫「無（理由）」（hd5-onboard 第 4 步；範本「建置、測試與執行指令」有這一行）')
    // Codex 沒有子代理定義：擔任 pm／sa／實作／qa 時要讀 .claude/agents/<角色>.md 本文（11-23 導入 IMOCore 拍板）
    if (!/\.claude\/agents/.test(ag)) warns.push('AGENTS.md 沒提到 `.claude/agents`：要寫明「Codex 擔任某角色時，完整讀 .claude/agents/<角色>.md 本文照做（忽略 frontmatter 的 tools／model）」（範本「AI 協作流程」有這一條）')
  }
  // CLAUDE.md
  const cl = rd('CLAUDE.md')
  if (cl === null) errors.push('缺 CLAUDE.md')
  else {
    const first = cl.split(/\r?\n/).find(l => l.trim())
    if (!first || first.trim() !== '@AGENTS.md') errors.push('CLAUDE.md 第一個非空行要是 @AGENTS.md（專案規則只寫在 AGENTS.md）')
    if (placeholders(cl).length) errors.push('CLAUDE.md 還有沒填的佔位符')
  }
  // workflow.json
  let wf = null
  const wfRaw = rd('.claude/workflow.json')
  if (wfRaw === null) errors.push('缺 .claude/workflow.json')
  else { try { wf = JSON.parse(wfRaw) } catch (e) { errors.push(`.claude/workflow.json 解析失敗：${e.message}`) } }
  if (wf) {
    if (!Array.isArray(wf.implementers) || !wf.implementers.length) errors.push('workflow.json 沒有 implementers（實作代理）')
    for (const i of wf.implementers || []) {
      if (!i.agent || !i.gateRole) { errors.push('workflow.json 的 implementer 缺 agent 或 gateRole'); continue }
      const body = rd(`.claude/agents/${i.agent}.md`)
      if (body === null) { errors.push(`workflow.json 指定的實作代理 ${i.agent} 沒有 .claude/agents/${i.agent}.md`); continue }
      const nm = (body.match(/^name:\s*(.+)$/m) || [])[1]?.trim()
      if (nm !== i.agent) errors.push(`.claude/agents/${i.agent}.md 的 name 是「${nm}」，跟 workflow.json 不一致`)
      if (body.includes(TEMPLATE_STACK_MARK)) errors.push(`${i.agent}.md 的「本專案技術架構重點」還是範本預設字——子代理很少讀 skills，架構重點一定要寫進本文`)
      if (!(i.extensions || []).length && !(i.pathHints || []).length) warns.push(`${i.agent} 沒有設定管哪些副檔名／目錄（main-edit-guard 無法建議派誰）`)
    }
    if (!(wf.productCode?.extensions || []).length) errors.push('workflow.json 沒有 productCode.extensions（main-edit-guard 不知道什麼算產品程式）')
    // 實作代理管的副檔名都要算產品程式，否則主對話改那種檔時 main-edit-guard 不會觸發（11-23 實測：把關驗不到本專案設定）
    const pc = new Set((wf.productCode?.extensions || []).map(e => String(e).toLowerCase()))
    for (const i of wf.implementers || []) {
      const miss = (i.extensions || []).filter(e => !pc.has(String(e).toLowerCase()) && !/^\.(css|scss|less|sql|md)$/i.test(e))
      if (miss.length) errors.push(`${i.agent} 管的 ${miss.join('、')} 不在 productCode.extensions：主對話改這些檔時 main-edit-guard 不會擋`)
    }
    // 分支命名要在導入一開始問使用者（11-23 使用者：未來要開的分支名稱要問使用 skills 的人）；空的 ⇒ main-edit-guard 會退回 project_／dev 而判錯分支
    for (const k of ['develop', 'workBranchPrefix']) if (!String(wf.branches?.[k] ?? '').trim()) errors.push(`workflow.json 的 branches.${k} 是空的：導入一開始要問使用者分支怎麼命名（開發分支、工作分支前綴，例 main＋feature/、dev＋project_）`)
    const tools = wf.paths?.tools
    if (!tools) errors.push('workflow.json 沒有 paths.tools')
    else if (!existsSync(join(proj, tools, 'validate-grill-gate.ps1'))) errors.push(`paths.tools（${tools}）底下沒有 validate-grill-gate.ps1`)
    const ttype = typeof wf.tracker === 'string' ? wf.tracker : wf.tracker?.type
    if (ttype === 'azure-devops') {
      if (tools && !existsSync(join(proj, tools, 'workitem', 'workitem-ops.ps1'))) errors.push(`tracker 是 azure-devops，但 ${tools}/workitem/ 沒有工單工具：重跑 install.ps1 -Tracker azure-devops`)
      if (!wf.tracker?.url) warns.push('tracker.url 是空的：只給工單號碼時工單工具找不到專案網址（要填 https://<主機>/<組織>/<專案>）')
    }
    // roleHints（例 tests/ 歸 qa-expert）：main-edit-guard 建議派誰時最先比；指到的代理要存在
    if (wf.roleHints !== undefined && !Array.isArray(wf.roleHints)) errors.push('workflow.json 的 roleHints 要是陣列：[{ agent, pathHints }]')
    for (const h of Array.isArray(wf.roleHints) ? wf.roleHints : []) {
      if (!h?.agent || !(h.pathHints || []).length) { errors.push('workflow.json 的 roleHints 每一筆都要有 agent 與 pathHints'); continue }
      if (rd(`.claude/agents/${h.agent}.md`) === null) errors.push(`workflow.json 的 roleHints 指定 ${h.agent}，但沒有 .claude/agents/${h.agent}.md`)
    }
    // excludeDirs 只比前綴（相對專案資料夾），**/ 才比任意層；寫了前綴、專案資料夾根沒有、底下某層有 ⇒ 多半是要寫 **/（舊寫法遷移）
    for (const d of wf.productCode?.excludeDirs || []) {
      const dd = String(d).replace(/\\/g, '/').replace(/^\/+/, '')
      if (!dd || dd.startsWith('**/') || existsSync(join(proj, dd))) continue
      if (findDirAnyLevel(proj, dd.replace(/\/+$/, ''))) warns.push(`productCode.excludeDirs「${d}」只比專案資料夾的前綴，但專案資料夾根沒有它、底下某層有：要排除任意層請寫「**/${dd}」`)
    }
    const ai = wf.paths?.aiService || 'AI_Service'
    if (!existsSync(join(proj, ai, 'verify'))) warns.push(`${ai}/verify 不存在：功能地圖還沒建（跑 verify-map-check.ps1 會列出缺什麼）`)
  }
  for (const n of ['pm-expert', 'sa-expert', 'qa-expert']) if (rd(`.claude/agents/${n}.md`) === null) errors.push(`缺 .claude/agents/${n}.md`)
  // sa-expert 流程要它建功能地圖骨架（verify/features/<編號>.md），「寫入路徑限制」卻沒放行功能地圖 ⇒ 兩段互相矛盾
  // （11-24 試跑：導入時保留了專案原本的代理本文，沒同步範本的寫入限制，SA 一定撞牆）
  const saBody = rd('.claude/agents/sa-expert.md'), saWrite = sectionBody(saBody, '寫入路徑限制')
  if (saBody && saWrite?.trim() && /verify\/features/.test(saBody.replace(saWrite, '')) && !/verify/.test(saWrite))
    warns.push('sa-expert.md 的流程要 SA 建功能地圖骨架（verify/features/），但「寫入路徑限制」沒有放行功能地圖資料夾：照範本補上「以及 <AI_Service>/verify/features/ 的功能骨架檔」')
  // 既有入口檔有備份 ⇒ 一定要有「既有規則去向表」：每條規則搬到 AGENTS.md 哪一節，或留在哪份文件（「一條都不能丟」的機械化）
  const ai2 = wf?.paths?.aiService || 'AI_Service'
  // 沒有 AI 入口檔時，規則從 README／docs 等流程文件整理成 architecture.md 的「既有規則清單」——同樣要有去向表（11-23 導入實測漏擋）
  const backup = join(proj, ai2, 'onboard', 'backup')
  const listed = tableRows(sectionBody(rd(`${ai2}/onboard/architecture.md`), '既有規則清單')).length
  const why = [existsSync(backup) && `有備份既有入口檔（${ai2}/onboard/backup/）`, listed && `architecture.md「既有規則清單」有 ${listed} 條`].filter(Boolean).join('、')
  if (why) {
    const mig = rd(`${ai2}/onboard/rules-migration.md`)
    const migRows = tableRows(mig).length
    if (mig === null) errors.push(`${why}，卻沒有 ${ai2}/onboard/rules-migration.md（既有規則去向表）`)
    else if (migRows < 2) errors.push('rules-migration.md 的去向表是空的（每條既有規則一列：規則｜原出處｜去向）')
    else if (migRows < listed) errors.push(`rules-migration.md 只有 ${migRows} 列，architecture.md「既有規則清單」有 ${listed} 條：每條都要有去向`)
  }
  // 導入問答：還標「待問」的題要擋（沒問完就產檔）；🟨 待補只警告
  const grill = rd(`${ai2}/onboard/onboard-grill.md`)
  if (grill !== null) {
    const pending = tableRows(grill).filter(r => r.some(c => /^(\*\*)?\s*待問/.test(c))).length +
      (grill.match(/^\s*[-*]\s.*狀態[:：]\s*(\*\*)?\s*待問/gm) || []).length
    if (pending) errors.push(`${ai2}/onboard/onboard-grill.md 還有 ${pending} 題標「待問」：問完使用者再產檔（問了答不出來的標 🟨 待補）`)
    const todo2 = (grill.match(/🟨\s*待補/g) || []).length
    if (todo2) warns.push(`onboard-grill.md 有 ${todo2} 題 🟨 待補（要列給使用者）`)
  }
  // settings.json hooks
  const st = rd('.claude/settings.json')
  if (st === null) errors.push('缺 .claude/settings.json（hook 沒註冊）')
  else {
    let s = null; try { s = JSON.parse(st) } catch (e) { errors.push(`.claude/settings.json 解析失敗：${e.message}`) }
    const cmds = (s?.hooks?.PreToolUse || []).flatMap(e => (e.hooks || []).map(h => ({ m: e.matcher, c: String(h.command || '') })))
    for (const [hook, matcher] of [['grill-gate.ps1', 'Agent'], ['main-edit-guard.ps1', 'Edit']]) {
      const hit = cmds.find(x => x.c.includes(hook) && String(x.m).includes(matcher))
      if (!hit) { errors.push(`settings.json 沒註冊 ${hook}`); continue }
      const paths = [...hit.c.matchAll(/"([^"]+\.ps1)"/g)].map(m => m[1])
      if (!paths.some(p => existsSync(join(proj, p)))) errors.push(`settings.json 的 ${hook} 指到的檔都不存在（以專案資料夾為準）：${paths.join('、')}`)
    }
  }
  // skills
  for (const d of ['.claude/skills/hd5-workflow/SKILL.md', '.agents/skills/hd5-workflow/SKILL.md']) if (!existsSync(join(proj, d))) errors.push(`缺 ${d}（${d.startsWith('.agents') ? 'Codex' : 'Claude'} 讀不到流程總綱）`)
  // .gitignore：導入產物合格卻進不了版控（11-23 導入 IMOCore：repo 根 .gitignore 有 IMOCore/CLAUDE.md、IMOCore/AGENTS.md）
  const ign = gitIgnored(proj, onboardArtifacts(proj, wf?.paths?.tools))
  const byRule = new Map()
  for (const x of ign || []) { const k = `${x.src} 第 ${x.line} 行「${x.pattern}」`; if (!byRule.has(k)) byRule.set(k, []); byRule.get(k).push(x) }
  for (const [k, xs] of byRule) errors.push(`被 git 忽略、進不了版控：${xs.slice(0, 4).map(x => x.path).join('、')}${xs.length > 4 ? ` 等 ${xs.length} 個` : ''}（${k}）——刪掉那一行，或在它後面加例外（例 !${xs[0].neg}）`)
  return { errors, warns }
}

const checkImpl = (...a) => check(...a)
export function selftest(check = checkImpl) {   // 可注入別版 check：拿新測項跑舊程式驗紅
  let fail = 0; const ok = (n, c) => { console.log(`  ${c ? 'ok  ' : 'FAIL'} ${n}`); if (!c) fail++ }
  const t = mkdtempSync(join(tmpdir(), 'hd5chk_'))
  const w = (p, s) => { mkdirSync(dirname(join(t, p)), { recursive: true }); writeFileSync(join(t, p), s) }
  const agents = REQUIRED_SECTIONS.map(s => `## ${s}\n內容\n`).join('\n')
  w('AGENTS.md', `# AGENTS\n${agents}`); w('CLAUDE.md', '@AGENTS.md\n\n# Claude\n')
  w('.claude/workflow.json', JSON.stringify({ paths: { aiService: 'AI_Service', tools: 'AI_Service/hd5-tools' }, branches: { develop: 'main', workBranchPrefix: 'feature/' }, implementers: [{ agent: 'backend-expert', gateRole: 'backend', extensions: ['.py'] }], productCode: { extensions: ['.py'] } }))
  w('AI_Service/hd5-tools/validate-grill-gate.ps1', '#'); w('AI_Service/hd5-tools/hooks/grill-gate.ps1', '#'); w('AI_Service/hd5-tools/hooks/main-edit-guard.ps1', '#'); mkdirSync(join(t, 'AI_Service/verify'), { recursive: true })
  for (const n of ['pm-expert', 'sa-expert', 'qa-expert', 'backend-expert']) w(`.claude/agents/${n}.md`, `---\nname: ${n}\n---\n## 本專案技術架構重點\nPython 3.12＋FastAPI\n`)
  w('.claude/settings.json', JSON.stringify({ hooks: { PreToolUse: [{ matcher: 'Task|Agent', hooks: [{ command: 'for p in "AI_Service/hd5-tools/hooks/grill-gate.ps1"; do' }] }, { matcher: 'Edit|Write', hooks: [{ command: 'for p in "AI_Service/hd5-tools/hooks/main-edit-guard.ps1"; do' }] }] } }))
  w('.claude/skills/hd5-workflow/SKILL.md', 'x'); w('.agents/skills/hd5-workflow/SKILL.md', 'x')
  ok('全部齊 ⇒ 合格', check(t).errors.length === 0)
  const saOk = '---\nname: sa-expert\n---\n## 流程\n地圖沒有就建骨架 `AI_Service/verify/features/<編號>.md`\n## 寫入路徑限制\n只寫 sa/，以及 `AI_Service/verify/features/` 的功能骨架檔\n'
  w('.claude/agents/sa-expert.md', saOk); ok('sa-expert 寫入限制有放行功能地圖 ⇒ 不警告', !check(t).warns.some(x => /寫入路徑限制/.test(x)))
  w('.claude/agents/sa-expert.md', saOk.replace('，以及 `AI_Service/verify/features/` 的功能骨架檔', '、CONTEXT.md、docs/adr/'))
  ok('sa-expert 流程要建地圖骨架、寫入限制沒放行 ⇒ 警告', check(t).warns.some(x => /sa-expert\.md.*寫入路徑限制/.test(x)) && check(t).errors.length === 0)
  w('.claude/agents/sa-expert.md', '---\nname: sa-expert\n---\n## 本專案技術架構重點\nPython 3.12＋FastAPI\n')
  w('AGENTS.md', `# AGENTS\n${agents.replace('## 人工閘門', '## 其他')}`); ok('缺「人工閘門」小節 ⇒ 擋', check(t).errors.some(e => /人工閘門/.test(e)))
  w('AGENTS.md', `# AGENTS\n${agents}\n{{專案名稱}}`); ok('殘留佔位符 ⇒ 擋', check(t).errors.some(e => /佔位符/.test(e)))
  w('AGENTS.md', `# AGENTS\n${agents}\n🟨 待補`); ok('🟨 待補 ⇒ 只警告', check(t).errors.length === 0 && check(t).warns.some(x => /待補/.test(x)))
  w('CLAUDE.md', '# Claude\n@AGENTS.md\n'); ok('CLAUDE.md 第一行不是 @AGENTS.md ⇒ 擋', check(t).errors.some(e => /@AGENTS\.md/.test(e))); w('CLAUDE.md', '@AGENTS.md\n')
  w('.claude/agents/backend-expert.md', `---\nname: backend-expert\n---\n（${TEMPLATE_STACK_MARK}；…）`); ok('實作代理架構重點還是範本 ⇒ 擋', check(t).errors.some(e => /範本預設字/.test(e)))
  w('.claude/agents/backend-expert.md', '---\nname: csharp-expert\n---\nx'); ok('代理 name 跟 workflow.json 不一致 ⇒ 擋', check(t).errors.some(e => /不一致/.test(e)))
  w('.claude/agents/backend-expert.md', '---\nname: backend-expert\n---\nx')
  rmSync(join(t, '.agents'), { recursive: true }); ok('缺 Codex 的 .agents/skills ⇒ 擋', check(t).errors.some(e => /Codex/.test(e)))
  w('.agents/skills/hd5-workflow/SKILL.md', 'x')
  rmSync(join(t, 'AI_Service/hd5-tools/hooks/main-edit-guard.ps1')); ok('hook 指到的檔不存在 ⇒ 擋', check(t).errors.some(e => /main-edit-guard\.ps1 指到的檔都不存在/.test(e)))
  w('AI_Service/hd5-tools/hooks/main-edit-guard.ps1', '#')
  w('.claude/workflow.json', JSON.stringify({ paths: { aiService: 'AI_Service', tools: 'AI_Service/hd5-tools' }, branches: { develop: 'main', workBranchPrefix: 'feature/' }, implementers: [{ agent: 'backend-expert', gateRole: 'backend', extensions: ['.py', '.go'] }], productCode: { extensions: ['.py'] } }))
  ok('實作代理管的副檔名不在 productCode ⇒ 擋', check(t).errors.some(e => /\.go 不在 productCode/.test(e)))
  w('.claude/workflow.json', JSON.stringify({ paths: { aiService: 'AI_Service', tools: 'AI_Service/hd5-tools' }, branches: { develop: 'main', workBranchPrefix: 'feature/' }, implementers: [{ agent: 'backend-expert', gateRole: 'backend', extensions: ['.py'] }], productCode: { extensions: ['.py'] } }))
  w('AI_Service/onboard/backup/CLAUDE.md', '舊的')
  ok('有備份卻沒有既有規則去向表 ⇒ 擋', check(t).errors.some(e => /rules-migration\.md/.test(e)))
  w('AI_Service/onboard/rules-migration.md', '| 規則 | 原出處 | 去向 |\n|---|---|---|\n| a | CLAUDE.md:1 | AGENTS.md 環境 |\n| b | CLAUDE.md:2 | AGENTS.md 指令 |\n| c | CLAUDE.md:3 | 留在 docs/x.md |\n')
  ok('去向表有內容 ⇒ 合格', check(t).errors.length === 0)
  const wfAdo = (url) => w('.claude/workflow.json', JSON.stringify({ paths: { aiService: 'AI_Service', tools: 'AI_Service/hd5-tools' }, tracker: { type: 'azure-devops', url }, branches: { develop: 'main', workBranchPrefix: 'feature/' }, implementers: [{ agent: 'backend-expert', gateRole: 'backend', extensions: ['.py'] }], productCode: { extensions: ['.py'] } }))
  wfAdo('https://dev.azure.com/o/p')
  ok('tracker=azure-devops 但沒裝工單工具 ⇒ 擋', check(t).errors.some(e => /workitem/.test(e)))
  w('AI_Service/hd5-tools/workitem/workitem-ops.ps1', '#')
  ok('裝了工單工具 ⇒ 合格', check(t).errors.length === 0)
  wfAdo('')
  ok('tracker.url 空 ⇒ 只警告', check(t).errors.length === 0 && check(t).warns.some(x => /tracker\.url/.test(x)))
  w('.claude/workflow.json', JSON.stringify({ paths: { aiService: 'AI_Service', tools: 'AI_Service/hd5-tools' }, branches: { develop: 'main', workBranchPrefix: '' }, implementers: [{ agent: 'backend-expert', gateRole: 'backend', extensions: ['.py'] }], productCode: { extensions: ['.py'] } }))
  ok('分支命名沒問（workBranchPrefix 空）⇒ 擋', check(t).errors.some(e => /branches\.workBranchPrefix/.test(e)))
  w('.claude/workflow.json', JSON.stringify({ paths: { aiService: 'AI_Service', tools: 'AI_Service/hd5-tools' }, implementers: [{ agent: 'backend-expert', gateRole: 'backend', extensions: ['.py'] }], productCode: { extensions: ['.py'] } }))
  ok('沒有 branches ⇒ 擋 develop 與 workBranchPrefix', check(t).errors.filter(e => /branches\./.test(e)).length === 2)
  // ── 11-23 導入實測補的項目 ──
  const wfOk = (extra = {}) => w('.claude/workflow.json', JSON.stringify({ paths: { aiService: 'AI_Service', tools: 'AI_Service/hd5-tools' }, branches: { develop: 'main', workBranchPrefix: 'feature/' }, implementers: [{ agent: 'backend-expert', gateRole: 'backend', extensions: ['.py'] }], productCode: { extensions: ['.py'] }, ...extra }))
  wfOk(); rmSync(join(t, 'AI_Service/onboard'), { recursive: true, force: true })
  ok('（底）回到合格狀態', check(t).errors.length === 0)
  // A1：程式碼裡的 {{…}} 不算佔位符
  w('AGENTS.md', `# AGENTS\n${agents}\n| 看容器 | \`docker compose ps --format "{{.Name}}"\` | 每次 | |\n\n\`\`\`\n{{#each items}}{{name}}{{/each}}\n\`\`\`\n`)
  ok('AGENTS.md 行內碼／程式碼區塊裡的 {{…}} ⇒ 不算佔位符', check(t).errors.length === 0)
  w('AGENTS.md', `# AGENTS\n${agents}\n\`docker ps\` 之後看 {{服務名稱}}\n`)
  ok('同一行行內碼外的 {{…}} ⇒ 仍擋', check(t).errors.some(e => /佔位符：\{\{服務名稱\}\}/.test(e)))
  w('AGENTS.md', `# AGENTS\n${agents}\n- 功能地圖：\`{{AI_Service}}/verify/\`\n`)
  ok('範本自己的佔位符寫在反引號裡（`{{AI_Service}}/verify/`）⇒ 仍擋', check(t).errors.some(e => /\{\{AI_Service\}\}/.test(e)))
  w('AGENTS.md', `# AGENTS\n${agents}`)
  w('CLAUDE.md', '@AGENTS.md\n\n```\ngo test -run "{{.Name}}"\n```\n'); ok('CLAUDE.md 程式碼區塊裡的 {{…}} ⇒ 不算', check(t).errors.length === 0); w('CLAUDE.md', '@AGENTS.md\n')
  // A3：architecture.md 有「既有規則清單」⇒ 要去向表；onboard-grill 的待問要擋
  const rulesList = '# 架構\n\n## 既有規則清單\n\n| 規則 | 出處 |\n|---|---|\n| 一律走 PR | README.md:12 |\n| 不可直接改 dist | docs/build.md:3 |\n| 禁止共用 DB 跑全套 | CONTRIBUTING.md:40 |\n\n## 其他\n| a | b |\n|---|---|\n| x | y |\n'
  w('AI_Service/onboard/architecture.md', rulesList)
  ok('🔴 沒有備份、但 architecture.md 有「既有規則清單」⇒ 要求 rules-migration.md', check(t).errors.some(e => /既有規則清單」有 3 條，卻沒有 .*rules-migration\.md/.test(e)))
  w('AI_Service/onboard/rules-migration.md', '| 規則 | 原出處 | 去向 |\n|---|---|---|\n| 一律走 PR | README.md:12 | AGENTS.md 分支 |\n| 不可直接改 dist | docs/build.md:3 | AGENTS.md 指令 |\n')
  ok('🔴 去向表列數少於既有規則清單 ⇒ 擋', check(t).errors.some(e => /只有 2 列.*有 3 條/.test(e)))
  w('AI_Service/onboard/rules-migration.md', '| 規則 | 原出處 | 去向 |\n|---|---|---|\n| 一律走 PR | README.md:12 | AGENTS.md 分支 |\n| 不可直接改 dist | docs/build.md:3 | AGENTS.md 指令 |\n| 禁止共用 DB 跑全套 | CONTRIBUTING.md:40 | AGENTS.md 指令 |\n')
  ok('去向表每條都有 ⇒ 合格', check(t).errors.length === 0)
  w('AI_Service/onboard/architecture.md', '# 架構\n\n## 既有規則清單\n\n沒有找到既有規則。\n')
  rmSync(join(t, 'AI_Service/onboard/rules-migration.md'))
  ok('既有規則清單沒有表格列（也沒有備份）⇒ 不要求去向表', check(t).errors.length === 0)
  w('AI_Service/onboard/onboard-grill.md', '# 導入問答\n狀態：已拍板／已查證／待問／🟨 待補\n\n| # | 題目 | 答案 | 狀態 |\n|---|---|---|---|\n| 1 | 測試怎麼跑才安全 | 只跑 unit | 已拍板 |\n| 2 | 部署方式 |  | 待問 |\n| 3 | 工單系統 | 不確定 | 🟨 待補 |\n')
  ok('🔴 onboard-grill.md 有「待問」⇒ 擋（說明行的「待問」不算）', check(t).errors.some(e => /還有 1 題標「待問」/.test(e)))
  w('AI_Service/onboard/onboard-grill.md', '# 導入問答\n\n| # | 題目 | 答案 | 狀態 |\n|---|---|---|---|\n| 1 | 測試怎麼跑才安全 | 只跑 unit | 已拍板 |\n| 3 | 工單系統 | 不確定 | 🟨 待補 |\n')
  ok('onboard-grill.md 只有 🟨 待補 ⇒ 只警告', check(t).errors.length === 0 && check(t).warns.some(x => /onboard-grill\.md 有 1 題 🟨 待補/.test(x)))
  // B1：roleHints 指到的代理要存在
  wfOk({ roleHints: [{ agent: 'qa-expert', pathHints: ['tests/'] }] }); ok('roleHints 指到存在的 qa-expert ⇒ 合格', check(t).errors.length === 0)
  wfOk({ roleHints: [{ agent: 'test-expert', pathHints: ['tests/'] }] }); ok('🔴 roleHints 指到不存在的代理 ⇒ 擋', check(t).errors.some(e => /roleHints 指定 test-expert/.test(e)))
  wfOk({ roleHints: [{ agent: 'qa-expert', pathHints: [] }] }); ok('roleHints 沒有 pathHints ⇒ 擋', check(t).errors.some(e => /roleHints 每一筆/.test(e)))
  // A2：excludeDirs 舊寫法（任意層）遷移提示
  mkdirSync(join(t, 'web/ClientApp/scripts'), { recursive: true })
  wfOk({ productCode: { extensions: ['.py'], excludeDirs: ['ClientApp/scripts/'] } })
  ok('excludeDirs 前綴在專案根不存在、底下某層有 ⇒ 警告要寫 **/', check(t).errors.length === 0 && check(t).warns.some(x => /\*\*\/ClientApp\/scripts\//.test(x)))
  wfOk({ productCode: { extensions: ['.py'], excludeDirs: ['**/ClientApp/scripts/'] } })
  ok('excludeDirs 寫 **/ ⇒ 不警告', !check(t).warns.some(x => /excludeDirs/.test(x)))
  // ── Codex 角色：AGENTS.md 要寫明擔任角色時讀 .claude/agents/<角色>.md（只警告）──
  ok('AGENTS.md 沒提到 .claude/agents ⇒ 警告（不擋）', check(t).errors.length === 0 && check(t).warns.some(x => /Codex 擔任某角色/.test(x)))
  w('AGENTS.md', `# AGENTS\n${agents}\n- Codex 擔任 pm／sa／實作／qa 時，完整讀 \`.claude/agents/<角色>.md\` 本文照做\n`)
  ok('AGENTS.md 有寫 .claude/agents ⇒ 不警告', !check(t).warns.some(x => /Codex 擔任某角色/.test(x)))
  const tplAg = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'templates', 'AGENTS.md.tpl'), 'utf8')
  w('AGENTS.md', tplAg.replace(/\{\{[^}]+\}\}/g, '（測試）'))
  ok('AGENTS.md 範本照填 ⇒ 不出 Codex 角色警告（範本有那一條）', !check(t).warns.some(x => /Codex 擔任某角色/.test(x)))
  ok('AGENTS.md 範本照填 ⇒ 不出弱點掃描警告（範本有那一行）', !check(t).warns.some(x => /相依套件弱點掃描/.test(x)))
  w('AGENTS.md', `# AGENTS\n${agents}`)
  ok('AGENTS.md 沒寫相依套件弱點掃描 ⇒ 警告（不擋）', check(t).errors.length === 0 && check(t).warns.some(x => /相依套件弱點掃描/.test(x)))
  // ── .gitignore：導入產物被忽略 ⇒ 擋（11-23 導入 IMOCore 實例）──
  const g = (cwd, ...a) => execFileSync('git', ['-C', cwd, ...a], { stdio: ['ignore', 'pipe', 'ignore'] })
  ok('（底）不是 git repo ⇒ 不檢查 .gitignore、合格', check(t).errors.length === 0)
  g(t, 'init', '-q'); g(t, 'config', 'core.autocrlf', 'false')
  ok('git repo、沒有忽略規則 ⇒ 合格', check(t).errors.length === 0)
  w('.gitignore', '# 個人檔\nCLAUDE.md\n')
  ok('🔴 .gitignore 忽略 CLAUDE.md ⇒ 擋，點名 .gitignore:2 與規則', check(t).errors.some(e => /被 git 忽略.*CLAUDE\.md.*repo 根的 \.gitignore 第 2 行「CLAUDE\.md」/.test(e)))
  w('.gitignore', 'AI_Service/hd5-tools/\n')
  ok('🔴 paths.tools 底下的工具被忽略 ⇒ 擋', check(t).errors.some(e => /被 git 忽略.*hd5-tools\/.*\.ps1.*第 1 行/.test(e)))
  w('.gitignore', '.claude/agents/*.md\n')
  ok('🔴 .claude/agents/*.md 被忽略 ⇒ 擋', check(t).errors.some(e => /被 git 忽略.*\.claude\/agents\/backend-expert\.md/.test(e)))
  w('.gitignore', '*.md\n*.json\n!AGENTS.md\n!CLAUDE.md\n!.claude/**/*.md\n!.agents/**/*.md\n!.claude/*.json\n')
  ok('「!」例外把產物放回來 ⇒ 合格', check(t).errors.length === 0)
  w('.gitignore', 'CLAUDE.md\n'); g(t, 'add', '-f', 'CLAUDE.md')
  ok('已追蹤的檔（git add -f 過）不算被忽略 ⇒ 合格', check(t).errors.length === 0)
  w('AI_Service/hd5-tools/workitem/pat.local.txt', 'x'); w('.gitignore', 'CLAUDE.md\npat.local.txt\n')
  ok('工具資料夾裡本來就該忽略的 PAT 檔（.txt）不算', check(t).errors.length === 0)
  // 專案在子資料夾、規則寫在 repo 根 .gitignore（IMOCore 型：repo 根有 IMOCore/AGENTS.md）
  const gr = mkdtempSync(join(tmpdir(), 'hd5chk_git_')); g(gr, 'init', '-q')
  mkdirSync(join(gr, 'app'), { recursive: true }); writeFileSync(join(gr, 'app', 'AGENTS.md'), '# x\n'); writeFileSync(join(gr, '.gitignore'), 'app/AGENTS.md\napp/CLAUDE.md\n')
  const ge = check(join(gr, 'app')).errors
  ok('🔴 子資料夾專案：repo 根 .gitignore 的 app/AGENTS.md、app/CLAUDE.md ⇒ 各自點名行號', ge.some(e => /AGENTS\.md.*repo 根的 \.gitignore 第 1 行「app\/AGENTS\.md」.*!app\/AGENTS\.md/.test(e)) && ge.some(e => /CLAUDE\.md.*第 2 行「app\/CLAUDE\.md」/.test(e)))
  writeFileSync(join(gr, '.gitignore'), ''); writeFileSync(join(gr, 'app', '.gitignore'), '# x\nAGENTS.md\n')
  ok('子資料夾自己的 .gitignore ⇒ 點名 app/.gitignore 第 2 行、例外寫相對它的 !AGENTS.md', check(join(gr, 'app')).errors.some(e => /AGENTS\.md（app\/\.gitignore 第 2 行「AGENTS\.md」）.*!AGENTS\.md）/.test(e)))
  rmSync(gr, { recursive: true, force: true })
  rmSync(t, { recursive: true, force: true })
  console.log(fail ? `selftest FAILED: ${fail}` : 'selftest ALL PASSED'); return fail ? 1 : 0
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const a = process.argv.slice(2)
  if (a.includes('--selftest')) process.exit(selftest())
  const i = a.indexOf('--project'); const proj = resolve(i >= 0 ? a[i + 1] : '.')
  const r = check(proj)
  if (a.includes('--json')) { console.log(JSON.stringify(r, null, 1)); process.exit(r.errors.length ? 1 : 0) }
  for (const w of r.warns) console.log(`⚠ ${w}`)
  for (const e of r.errors) console.log(`❌ ${e}`)
  console.log(r.errors.length ? `❌ 導入未完成：${r.errors.length} 處` : '✅ 導入產物合格')
  process.exit(r.errors.length ? 1 : 0)
}
