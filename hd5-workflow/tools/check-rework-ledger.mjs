// check-rework-ledger.mjs — 跨案子退回總帳（AI_Service/spec/rework-ledger.md）與案子退回紀錄的對帳（2026-11-25）
//
// 為什麼：Lauren Tan「糾正一次就變成確定性檢查」。驗收退回 → 寫出「錯的程式寫法」→ 做成程式守衛，這個循環原本只寫在文字
//   （hd5-workflow「驗收退回之後」、hd5-case-report 第七節），退回沒記、結案報告沒補 5.1、同一類寫法第二次出現還是只寫「先記帳」，都沒有東西擋。
//   流程閘只擋「循環有沒有斷」（有沒有記帳、三方對不對得上）；「程式寫法類要有程式守衛、待辦拖著又再犯」只讓開發端的 verify 變紅，不在工單閘擋人。
//
// 檢查：
//   A. 總帳（不存在＝尚無退回，通過）
//      1. 表頭 8 欄：| 結案日 | 案號 | 輪次 | 根因類別 | 錯誤寫法 | 原因一句 | 為什麼沒先抓到 | 對應規則 |；每列欄位數要對、輪次寫 R{n}
//      2. 根因類別在固定清單內（CATEGORIES）
//      3. 錯誤寫法：一句話寫出錯的程式寫法長什麼樣，不可空；根因類別＝規則定義晚／新需求／缺證據或使用者動作時可寫 不是程式寫法（理由）
//      4. 對應規則（可多項，用「、」分隔，判定與 check-guard-refs 的守衛欄同一套）：
//           守衛名（xxx.ps1／.mjs、XxxTests、guard:xxx、個人 hook）  要真的存在
//           待辦（G-NN）                                          G-NN 要在 AI_Service/spec/guard-backlog.md
//           無（理由）                                            理由不可空
//           無法預防（理由）                                      只限根因類別＝新需求，理由不可空
//      5. 只有 verify 模式（--gate 不檢查）：
//         a. 程式寫法類（樣本不足／修後沒重跑／測試資料形狀／動作順序／其他）第一次出現就要對應「程式守衛」：測試類別、guard:xxx、
//            HD5 流程工具以外的腳本（棘輪、lint、架構檢查）；做不到先列 待辦（G-NN）。無（理由）、流程閘（HD5 工具、hook）、文字都不算
//            需求類（規則定義晚／新需求／缺證據或使用者動作）才可只寫 無（理由）／無法預防（理由）
//         b. 同類再犯（同一根因類別在總帳出現 ≥2 次，跨案子也算；新需求除外）：較早那列的 待辦（G-NN）還沒做成守衛（該列沒有程式守衛）⇒ 紅。
//            「較早」看結案日，同日看檔案順序；守衛做好後把那列的對應規則改成實際守衛名
//   B. 案子（--case；工單閘改待驗收／驗收完成、上傳結案報告時用 --gate 呼叫）
//      rework-log 表要有「根因類別」「錯誤寫法」欄（規則同 A3）
//      --stage accept --rejections k：工單歷程退回 k 次 ⇒ qa/rework-log.md 至少要記 k 輪（R1、R2…；同一輪多列算一輪）
//      --stage done：rework-log 有 m 列 ⇒ ai-case-report.md 有「### 5.1」節且表格 m 列、有「錯誤寫法」欄（m＝0 要寫「退回 0 次」）、
//                    總帳有本案案號 m 列（案號：--id，沒給就取報告第一行的 #NNN）
//   C. 不帶 --case 的 --check：A＋已結案的案子（報告 5.1 已填，或案號出現在總帳）都跑 B 的 done 檢查
//
// 用法：node check-rework-ledger.mjs --check [--root <repo 根或專案資料夾>]              verify 模式（含升級），不合格 exit 1
//       node check-rework-ledger.mjs --check --gate --case <AI_Service/spec/<案名>> --stage accept|done [--rejections k] [--id NNN]
//                                                                                     工單閘模式：只查格式與對帳，不查升級
//       node check-rework-ledger.mjs --list  [--root …]   列出總帳每列、根因類別次數
//       node check-rework-ledger.mjs --selftest
import { readFileSync, existsSync, readdirSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { locate, makeResolver, parseGuardRefs } from './check-guard-refs.mjs'

const here = dirname(fileURLToPath(import.meta.url))

export const CATEGORIES = ['樣本不足', '規則定義晚', '修後沒重跑', '測試資料形狀', '動作順序', '缺證據或使用者動作', '新需求', '其他']
export const EXEMPT = ['新需求']
export const PROGRAM_CATEGORIES = ['樣本不足', '修後沒重跑', '測試資料形狀', '動作順序', '其他']   // 程式寫法類：第二次要程式守衛
export const NOT_CODE_OK = ['規則定義晚', '新需求', '缺證據或使用者動作']                          // 可寫「不是程式寫法（理由）」
export const LEDGER_HEADER = ['結案日', '案號', '輪次', '根因類別', '錯誤寫法', '原因一句', '為什麼沒先抓到', '對應規則']

// ── Markdown 表格 ──
export function splitRow(line) {
  const s = line.trim()
  if (!s.startsWith('|')) return null
  return s.replace(/^\|/, '').replace(/(?<!\\)\|\s*$/, '').split(/(?<!\\)\|/).map(c => c.trim())
}
const isSep = cells => cells.length > 0 && cells.every(c => /^:?-{2,}:?$/.test(c))
export function parseTables(text, lineOffset = 0) {
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  const tables = []; let fence = false, cur = null
  lines.forEach((l, i) => {
    if (/^\s*(```|~~~)/.test(l)) { fence = !fence; cur = null; return }
    if (fence) return
    const cells = splitRow(l)
    if (!cells) { cur = null; return }
    if (!cur) { cur = { header: cells, line: i + 1 + lineOffset, rows: [], sep: false }; tables.push(cur); return }
    if (!cur.sep && isSep(cells)) { cur.sep = true; return }
    cur.rows.push({ cells, line: i + 1 + lineOffset })
  })
  return tables.filter(t => t.sep)
}
const normId = s => String(s ?? '').replace(/`/g, '').trim().replace(/^#/, '').trim()
const col = (header, name) => header.findIndex(h => h.includes(name))

// 錯誤寫法欄：回傳錯誤陣列
export function judgeBadPattern(cell, category) {
  const v = String(cell ?? '').replace(/`/g, '').trim()
  if (!v) return ['錯誤寫法是空的：一句話寫出錯的程式寫法長什麼樣（例：用「有沒有修改人」判斷「有沒有修改」）']
  const m = /^不是程式寫法\s*[（(](.*)[）)]$/.exec(v)
  if (!m) return []
  const e = []
  if (!m[1].trim()) e.push('「不是程式寫法（理由）」理由是空的')
  if (!NOT_CODE_OK.includes(category)) e.push(`「不是程式寫法」只限根因類別＝${NOT_CODE_OK.join('／')}（這列是「${category}」）：程式寫法類要寫出錯的寫法`)
  return e
}

// ── 案子的退回紀錄與結案報告 ──
// 回傳 { rows: [{ round, line, category, bad }], rounds, missingBadCol, missingCatCol }
export function parseReworkLog(text) {
  const rows = []; let missingBadCol = false, missingCatCol = false
  for (const t of parseTables(text)) {
    const ib = col(t.header, '錯誤寫法'), ic = col(t.header, '根因類別')
    for (const r of t.rows) {
      const m = /^R(\d+)/.exec(r.cells[0] || '')
      if (!m) continue
      if (ib < 0) missingBadCol = true
      if (ic < 0) missingCatCol = true
      rows.push({ round: +m[1], line: r.line, category: ic >= 0 ? r.cells[ic] : '', bad: ib >= 0 ? r.cells[ib] : null })
    }
  }
  return { rows, rounds: new Set(rows.map(r => r.round)), missingBadCol, missingCatCol }
}
export function parseReport51(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  const start = lines.findIndex(l => /^###\s*5\.1(?!\d)/.test(l))
  const head = lines.find(l => /^#\s/.test(l)) || ''
  const idm = /#(\d+)/.exec(head.replace(/^#\s*/, ''))
  const id = idm ? idm[1] : null
  if (start < 0) return { found: false, rows: 0, zero: false, heading: '', id, badErrors: [] }
  let end = lines.length
  for (let j = start + 1; j < lines.length; j++) if (/^#{1,3}\s/.test(lines[j])) { end = j; break }
  const sec = lines.slice(start, end).join('\n')
  let rows = 0; const badErrors = []
  for (const t of parseTables(sec, start)) {
    rows += t.rows.length
    if (!t.rows.length) continue
    const ib = col(t.header, '錯誤寫法'), ic = col(t.header, '根因類別')
    if (ib < 0) { badErrors.push('5.1 表格缺「錯誤寫法」欄'); continue }
    for (const r of t.rows) for (const e of judgeBadPattern(r.cells[ib], ic >= 0 ? r.cells[ic] : '')) badErrors.push(`5.1 第 ${r.line} 行 ${e}`)
  }
  return { found: true, rows, zero: /退回\s*0\s*次/.test(sec), heading: lines[start], id, badErrors }
}

// ── 對應規則 ──
// 判定一格「對應規則」：回傳 { refs, errors, warns, hasGuard, hasProgramGuard }。守衛名的判定直接用 check-guard-refs 的 resolver（同一套）。
// 程式守衛＝測試類別、guard:xxx、HD5 流程工具以外的腳本（processGates 裡的名字＝流程閘，不算）。
export function judgeRule(cell, category, resolveRef, processGates = new Set()) {
  const errors = [], warns = []
  const refs = String(cell ?? '').trim() ? parseGuardRefs('守衛：' + cell) : []
  if (!refs.length) return { refs, errors: ['對應規則是空的：要寫守衛名、待辦（G-NN）、無（理由），或新需求才能用的 無法預防（理由）'], warns, hasGuard: false, hasProgramGuard: false, todos: [] }
  let hasGuard = false, hasProgramGuard = false; const todos = []
  for (const ref of refs) {
    const m = /^無法預防\s*[（(](.*)[）)]$/.exec(ref)
    if (m) {
      if (!m[1].trim()) errors.push('「無法預防（理由）」理由是空的')
      if (!EXEMPT.includes(category)) errors.push(`「${ref}」只限根因類別＝新需求（這列是「${category}」）：要寫守衛名、待辦（G-NN）或無（理由）`)
      continue
    }
    const v = resolveRef(ref)
    if (!v.ok) { errors.push(/^看不懂/.test(v.why) ? `看不懂「${ref}」：對應規則要寫守衛名（xxx.ps1、XxxTests…）、待辦（G-NN）、無（理由），新需求可寫 無法預防（理由）；說明文字放進括號裡` : v.why); continue }
    if (v.warn) warns.push(`${ref}：${v.warn}`)
    if (v.kind === '待辦') { todos.push(/G-\d+/.exec(ref)[0]); continue }
    if (v.kind === '無') continue
    hasGuard = true
    if (v.kind === '測試' || v.kind === 'npm' || (v.kind === '腳本' && !processGates.has(ref))) hasProgramGuard = true
  }
  return { refs, errors, warns, hasGuard, hasProgramGuard, todos }
}

// opts.escalate：要不要查「同類第二次要升級」（verify 模式 true；工單閘 --gate 為 false）
export function checkLedger(text, resolveRef, opts = {}) {
  const { escalate = true, processGates = new Set() } = opts
  const errors = [], warns = [], rows = []
  const table = parseTables(text).find(t => t.header.some(h => h.includes('根因類別')))
  if (!table) return { errors: ['找不到總帳表格（表頭要有「根因類別」）：' + LEDGER_HEADER.map(h => `| ${h} `).join('') + '|'], warns, rows }
  if (table.header.length !== LEDGER_HEADER.length) errors.push(`${table.line} 表頭 ${table.header.length} 欄，應為 ${LEDGER_HEADER.length} 欄：${LEDGER_HEADER.join('／')}`)
  table.rows.forEach((r, idx) => {
    const c = r.cells
    if (c.length !== LEDGER_HEADER.length) { errors.push(`${r.line} 欄位 ${c.length} 欄，應為 ${LEDGER_HEADER.length} 欄（${LEDGER_HEADER.join('／')}）`); return }
    const [date, id, round, category, bad, , , rule] = c
    if (!/^R\d+/.test(round)) errors.push(`${r.line} 輪次「${round}」要寫 R{n}（R1、R2…）`)
    if (!CATEGORIES.includes(category)) errors.push(`${r.line} 根因類別「${category}」不在清單：${CATEGORIES.join('／')}`)
    for (const e of judgeBadPattern(bad, category)) errors.push(`${r.line} ${e}`)
    const j = judgeRule(rule, category, resolveRef, processGates)
    for (const e of j.errors) errors.push(`${r.line} ${e}`)
    for (const wv of j.warns) warns.push(`rework-ledger.md:${r.line} ${wv}`)
    rows.push({ line: r.line, order: idx, date: /^\d{4}-\d{2}-\d{2}/.test(date) ? date.slice(0, 10) : '', id: normId(id), round, category, refs: j.refs, hasGuard: j.hasGuard, hasProgramGuard: j.hasProgramGuard, todos: j.todos })
  })
  if (!escalate) return { errors, warns, rows }
  // V1 程式寫法類：第一次就要程式守衛，做不到先列 待辦（G-NN）；無（理由）、流程閘、文字都不算（糾正一次就變成確定性檢查）
  for (const r of rows) if (PROGRAM_CATEGORIES.includes(r.category) && !r.hasProgramGuard && !r.todos.length)
    errors.push(`${r.line} ${r.category} 是程式寫法類：對應規則要含程式守衛（測試類別、guard:xxx、棘輪／lint／架構檢查腳本）或 待辦（G-NN）；無（理由）、流程閘、文字都不算`)
  // V2 同類再犯：較早那列的 待辦（G-NN）還沒做成守衛（該列沒有程式守衛）⇒ 紅，點較早那列
  const by = new Map()
  for (const r of rows) if (CATEGORIES.includes(r.category) && !EXEMPT.includes(r.category)) by.set(r.category, [...(by.get(r.category) || []), r])
  for (const [cat, list] of by) {
    if (list.length < 2) continue
    const sorted = [...list].sort((a, b) => (a.date === b.date ? a.order - b.order : a.date < b.date ? -1 : 1))
    const latest = sorted.at(-1)
    for (const e of sorted.slice(0, -1)) if (e.todos.length && !e.hasProgramGuard)
      errors.push(`${e.line} ${cat} 再犯（#${latest.id} ${latest.round}）：前一次的 ${e.todos.join('、')} 還沒做成守衛——先做守衛，做好就把那列對應規則改成實際守衛名（待辦拖著沒做又犯了）`)
  }
  return { errors, warns, rows }
}

export function checkCase({ caseDir, stage, rejections = 0, id = null, ledgerRows = [] }) {
  const errors = []
  const name = caseDir.replace(/\\/g, '/').split('/').filter(Boolean).at(-1)
  const logPath = join(caseDir, 'qa', 'rework-log.md')
  const log = existsSync(logPath) ? parseReworkLog(readFileSync(logPath, 'utf8')) : { rows: [], rounds: new Set() }
  if (log.missingBadCol) errors.push(`${name}：qa/rework-log.md 表頭缺「錯誤寫法」欄（一句話寫出錯的程式寫法；規則定義晚／新需求／缺證據或使用者動作可寫 不是程式寫法（理由））`)
  if (log.missingCatCol) errors.push(`${name}：qa/rework-log.md 表頭缺「根因類別」欄`)
  for (const r of log.rows) if (r.bad !== null) for (const e of judgeBadPattern(r.bad, r.category)) errors.push(`${name}：qa/rework-log.md 第 ${r.line} 行 ${e}`)
  const k = Number(rejections) || 0
  if (k > 0 && log.rounds.size < k) {
    const from = log.rounds.size + 1
    errors.push(`${name}：工單歷程退回 ${k} 次，qa/rework-log.md 只記了 ${log.rounds.size} 輪：要先記第 ${from === k ? from : `${from}～${k}`} 輪退回（每輪一列：輪次 R{n}、退回原因、處理類別、根因類別、錯誤寫法、為什麼開發端沒先抓到；hd5-workflow「驗收退回之後」）`)
  }
  if (stage !== 'done') return errors
  const m = log.rows.length
  const rp = join(caseDir, 'ai-case-report.md')
  if (!existsSync(rp)) { errors.push(`${name}：找不到 ai-case-report.md——需求方驗收完成後要補第 5.1 節退回檢討（hd5-case-report 第七節）`); return errors }
  const s = parseReport51(readFileSync(rp, 'utf8'))
  const caseId = normId(id || s.id || '')
  if (!s.found) errors.push(`${name}：ai-case-report.md 沒有「### 5.1」退回檢討節（rework-log ${m} 列${m ? '' : '；沒退回也要寫「退回 0 次」'}）`)
  else if (m > 0 && s.rows !== m) errors.push(`${name}：ai-case-report.md 5.1 表格 ${s.rows} 列，rework-log 有 ${m} 列——每次退回一列`)
  else if (m === 0 && (s.rows > 0 || !s.zero)) errors.push(`${name}：rework-log 沒有退回，5.1 要寫「退回 0 次」${s.rows ? `（表格卻有 ${s.rows} 列）` : ''}`)
  if (s.found) for (const e of s.badErrors) errors.push(`${name}：ai-case-report.md ${e}`)
  if (!caseId) errors.push(`${name}：不知道本案案號（給 --id，或報告第一行寫 #NNN），無法對總帳`)
  else {
    const n = ledgerRows.filter(r => r.id === caseId).length
    if (n !== m) errors.push(`${name}：總帳 rework-ledger.md 有本案 #${caseId} ${n} 列，rework-log 有 ${m} 列——每次退回都要記進總帳（hd5-case-report 第七節）`)
  }
  return errors
}

function findProjectFrom(dir) {
  let d = resolve(dir)
  for (let i = 0; i < 12; i++) { if (existsSync(join(d, '.claude', 'workflow.json'))) return d; const p = dirname(d); if (p === d) break; d = p }
  return resolve(dir, '..', '..', '..')   // <專案>/AI_Service/spec/<案名>
}
function fileNames(d, out, depth = 0) {
  if (depth > 6) return out
  let es; try { es = readdirSync(d, { withFileTypes: true }) } catch { return out }
  for (const e of es) { if (e.isDirectory()) { if (!/^(node_modules|\.git|tests?)$/.test(e.name)) fileNames(join(d, e.name), out, depth + 1) } else out.add(e.name) }
  return out
}
// 流程閘＝HD5 流程工具（本工具所在資料夾、套件原始碼的工單工具、專案 hd5-tools）＋ workflow.json guards.processGates
export function processGateNames(loc) {
  const s = new Set()
  fileNames(here, s); fileNames(join(here, '..', '..', 'hd5-workitem', 'scripts'), s); fileNames(join(loc.ai, 'hd5-tools'), s)
  for (const b of [resolve(loc.ai, '..')]) {
    try { const wf = JSON.parse(readFileSync(join(b, '.claude', 'workflow.json'), 'utf8').replace(/^﻿/, '')); for (const n of wf.guards?.processGates || []) s.add(String(n)) } catch { }
    try { const wf = JSON.parse(readFileSync(join(b, '.claude', 'workflow.json'), 'utf8').replace(/^﻿/, '')); if (wf.paths?.tools) fileNames(resolve(b, wf.paths.tools), s) } catch { }
  }
  return s
}

export function check(root, opts = {}) {
  const loc = locate(root)
  const resolveRef = makeResolver(loc, opts)
  const ledgerPath = join(loc.ai, 'spec', 'rework-ledger.md')
  const exists = existsSync(ledgerPath)
  const L = exists ? checkLedger(readFileSync(ledgerPath, 'utf8'), resolveRef, { escalate: !opts.gate, processGates: processGateNames(loc) }) : { errors: [], warns: [], rows: [] }
  const errors = L.errors.map(e => `rework-ledger.md:${e}`), warns = [...L.warns]
  if (opts.caseDir) {
    errors.push(...checkCase({ caseDir: opts.caseDir, stage: opts.stage, rejections: opts.rejections, id: opts.id, ledgerRows: L.rows }))
  } else {
    // 已結案的案子：報告 5.1 已填（有表格列或寫了退回 0 次），或案號出現在總帳
    const ledgerIds = new Set(L.rows.map(r => r.id))
    const spec = join(loc.ai, 'spec')
    let dirs = []; try { dirs = readdirSync(spec, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => join(spec, e.name)) } catch { }
    for (const d of dirs.sort()) {
      const rp = join(d, 'ai-case-report.md'); if (!existsSync(rp)) continue
      const s = parseReport51(readFileSync(rp, 'utf8'))
      if ((s.found && (s.rows > 0 || s.zero)) || (s.id && ledgerIds.has(s.id))) errors.push(...checkCase({ caseDir: d, stage: 'done', id: s.id, ledgerRows: L.rows }))
    }
  }
  return { errors, warns, rows: L.rows, ledgerPath, exists }
}

const checkImpl = (...a) => check(...a)
export function selftest(check = checkImpl) {   // 可注入別版 check：拿新測項跑舊程式驗紅
  const t = mkdtempSync(join(tmpdir(), 'reworkledger_'))
  const w = (p, s) => { mkdirSync(dirname(join(t, p)), { recursive: true }); writeFileSync(join(t, p), s) }
  const P = join(t, 'P')
  w('P/.claude/workflow.json', '{}')
  w('P/AI_Service/spec/guard-backlog.md', '| G-01 | x |\n')
  w('P/AI_Service/hd5-tools/workitem/_acceptance-gate.ps1', '')      // 流程閘
  w('P/AI_Service/hd5-tools/check-rework-ledger.mjs', '')            // 流程閘
  w('P/scripts/ratchet-null-check.mjs', '')                          // 程式守衛：棘輪腳本（HD5 流程工具以外）
  w('P/tests/NullNameGuardTests.cs', 'public class NullNameGuardTests { }')   // 程式守衛：測試類別
  const HEAD = '| 結案日 | 案號 | 輪次 | 根因類別 | 錯誤寫法 | 原因一句 | 為什麼沒先抓到 | 對應規則 |\n|---|---|---|---|---|---|---|---|\n'
  const row = (cat, rule, o = {}) => `| ${o.date || '2026-11-25'} | ${o.id || '#100'} | ${o.r || 'R1'} | ${cat} | ${o.bad ?? '名稱只讀 Name 欄、沒退到 EquipmentName'} | 原因 | 沒抓到 | ${rule} |\n`
  const ledgerFile = 'P/AI_Service/spec/rework-ledger.md'
  const L = (...rows) => { w(ledgerFile, '# 跨案子退回總帳\n\n' + HEAD + rows.join('')); return check(P) }
  const LG = (...rows) => { w(ledgerFile, HEAD + rows.join('')); return check(P, { gate: true }) }
  let fail = 0
  const ok = (name, c, r) => { console.log(`  ${c ? 'ok  ' : 'FAIL'} ${name}`); if (!c) { fail++; if (r) for (const e of r.errors || []) console.log(`       ${e}`) } }
  const has = (r, re) => r.errors.some(e => re.test(e))

  // ── A. 總帳 ──
  { const r = check(P); ok('總帳不存在 ⇒ 通過（尚無退回）', r.errors.length === 0 && !r.exists, r) }
  { const r = L(row('樣本不足', 'NullNameGuardTests')); ok('一列（8 欄）、對應規則是存在的守衛名 ⇒ 過', r.errors.length === 0 && r.rows.length === 1, r) }
  { const r = L('| 2026-11-25 | #100 | R1 | 樣本不足 | 原因 | 沒抓到 | _acceptance-gate.ps1 |\n'); ok('🔴 舊的 7 欄格式 ⇒ 錯（點出行號、應為 8 欄）', has(r, /:5 .*欄位 7.*應為 8/), r) }
  { const r = L(row('不小心', '無（x）')); ok('根因類別不在固定清單 ⇒ 錯', has(r, /根因類別「不小心」不在清單/), r) }
  { const r = L(row('樣本不足', '無（x）', { bad: '' })); ok('🔴 錯誤寫法空白 ⇒ 錯', has(r, /錯誤寫法是空的/), r) }
  { const r = L(row('規則定義晚', '無（x）', { bad: '不是程式寫法（需求方驗收時才定義「修改」）' })); ok('不是程式寫法（理由）＋規則定義晚 ⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('缺證據或使用者動作', '無（x）', { bad: '不是程式寫法（開機自啟要使用者設定）' })); ok('不是程式寫法（理由）＋缺證據或使用者動作 ⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('樣本不足', '無（x）', { bad: '不是程式寫法（只是沒測到）' })); ok('🔴 不是程式寫法 用在程式寫法類（樣本不足）⇒ 錯', has(r, /不是程式寫法」只限根因類別/), r) }
  { const r = L(row('規則定義晚', '無（x）', { bad: '不是程式寫法（）' })); ok('不是程式寫法（）理由空 ⇒ 錯', has(r, /不是程式寫法（理由）」理由是空的/), r) }
  { const r = L(row('規則定義晚', '無（要人判斷）')); ok('需求類 無（理由）⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('樣本不足', '無（）')); ok('無（）理由空 ⇒ 錯', has(r, /理由是空的/), r) }
  { const r = L(row('樣本不足', '待辦（G-01）')); ok('待辦（G-01）在 guard-backlog ⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('樣本不足', '待辦（G-99）')); ok('待辦（G-99）不在 guard-backlog ⇒ 錯', has(r, /guard-backlog\.md 沒有 G-99/), r) }
  { const r = L(row('新需求', '無法預防（驗收時才提的新需求）', { bad: '不是程式寫法（新需求）' })); ok('無法預防（理由）＋新需求 ⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('樣本不足', '無法預防（不想做）')); ok('無法預防 用在新需求以外 ⇒ 錯', has(r, /無法預防.*只限根因類別＝新需求/), r) }
  { const r = L(row('新需求', '無法預防（）', { bad: '不是程式寫法（x）' })); ok('無法預防（）理由空 ⇒ 錯', has(r, /無法預防.*理由是空的/), r) }
  { const r = L(row('樣本不足', '缺 ⇒ 已補：hd5-grill 第三節第九分支（母版 9a49443）')); ok('自由文字（舊格式）⇒ 錯', has(r, /看不懂/), r) }
  { const r = L(row('樣本不足', '')); ok('對應規則空白 ⇒ 錯', has(r, /對應規則是空的/), r) }
  { const r = L(row('規則定義晚', '無（skill 第三節、要人判斷）、`check-rework-ledger.mjs`')); ok('多項用「、」分隔、理由內的「、」不切、可包反引號 ⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('樣本不足', 'nope-guard.ps1')); ok('守衛名不存在 ⇒ 錯', has(r, /找不到腳本 nope-guard\.ps1/), r) }
  { const r = L(row('樣本不足', '無（x）', { r: '第一輪' })); ok('輪次不是 R{n} ⇒ 錯', has(r, /輪次「第一輪」要寫 R/), r) }
  // ── A5. 程式寫法類：第一次就要程式守衛或待辦（verify 模式）──
  { const r = L(row('動作順序', '無（先記帳）')); ok('🔴 程式寫法類第一次只寫 無（理由）⇒ 錯「要含程式守衛或待辦」', has(r, /動作順序 是程式寫法類：對應規則要含程式守衛.*或 待辦/), r) }
  { const r = L(row('樣本不足', '_acceptance-gate.ps1、check-rework-ledger.mjs')); ok('🔴 程式寫法類只填流程閘 ⇒ 錯', has(r, /樣本不足 是程式寫法類/), r) }
  { const r = L(row('測試資料形狀', 'NullNameGuardTests')); ok('程式寫法類有測試類別 ⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('測試資料形狀', '無（b）、ratchet-null-check.mjs')); ok('程式寫法類有棘輪腳本（HD5 流程工具以外）⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('修後沒重跑', '無（守衛還沒做）、待辦（G-01）')); ok('程式寫法類先列 待辦（G-NN）⇒ 過', r.errors.length === 0, r) }
  w('P/.claude/workflow.json', JSON.stringify({ guards: { processGates: ['ratchet-null-check.mjs'] } }))
  { const r = L(row('測試資料形狀', 'ratchet-null-check.mjs')); ok('workflow.json guards.processGates 列的腳本算流程閘 ⇒ 只有它 ⇒ 錯', has(r, /測試資料形狀 是程式寫法類/), r) }
  w('P/.claude/workflow.json', '{}')
  { const r = L(row('規則定義晚', '無（需求方才定義）', { id: '#1' }), row('規則定義晚', '無（又是驗收才定義）', { id: '#2' })); ok('需求類（規則定義晚）寫 無 ⇒ 過，出現兩次也過', r.errors.length === 0, r) }
  { const r = L(row('缺證據或使用者動作', '無（要使用者設定）', { bad: '不是程式寫法（開機自啟要使用者設定）' })); ok('需求類（缺證據或使用者動作）寫 無 ⇒ 過', r.errors.length === 0, r) }
  // ── A6. 同類再犯：前一次的 待辦 還沒做成守衛 ⇒ 紅 ──
  { const r = L(row('動作順序', '待辦（G-01）', { id: '#100' }), row('動作順序', 'NullNameGuardTests', { id: '#200' }))
    ok('🔴 同類再犯、前一次的 待辦（G-01）還沒做成守衛 ⇒ 錯（點前一次那列）', has(r, /:5 動作順序 再犯（#200 R1）：前一次的 G-01 還沒做成守衛/), r) }
  { const r = L(row('動作順序', 'NullNameGuardTests', { id: '#100' }), row('動作順序', '待辦（G-01）', { id: '#200' }))
    ok('同類再犯、前一次已是實際守衛、這次先列待辦 ⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('動作順序', '待辦（G-01）', { id: '#200', date: '2026-12-01' }), row('動作順序', 'NullNameGuardTests', { id: '#100', date: '2026-11-01' }))
    ok('「前一次」看結案日、不看檔案順序：較新那列才是待辦 ⇒ 過', r.errors.length === 0, r) }
  { const r = L(row('動作順序', '待辦（G-01）', { id: '#1' }), row('動作順序', '待辦（G-01）', { id: '#2' }), row('動作順序', '待辦（G-01）', { id: '#3' }))
    ok('同類第 3 次、前兩次都只是待辦 ⇒ 前兩列各紅一次', r.errors.filter(e => /再犯/.test(e)).length === 2, r) }
  { const r = L(row('新需求', '無法預防（a）', { id: '#1', bad: '不是程式寫法（x）' }), row('新需求', '無法預防（b）', { id: '#2', bad: '不是程式寫法（y）' }))
    ok('新需求出現 2 次 ⇒ 豁免', r.errors.length === 0, r) }
  // ── --gate（工單閘模式）不查 A5／A6，其餘照查 ──
  { const r = LG(row('動作順序', '無（a）', { id: '#1' })); ok('🔴 --gate：程式寫法類只寫 無 ⇒ 不擋（只在 verify 紅）', r.errors.length === 0, r) }
  { const r = LG(row('動作順序', '待辦（G-01）', { id: '#1' }), row('動作順序', '待辦（G-01）', { id: '#2' })); ok('--gate：待辦沒做又再犯 ⇒ 不擋', r.errors.length === 0, r) }
  { const r = LG(row('動作順序', '缺（先記帳）')); ok('--gate：格式錯（自由文字）照樣擋', has(r, /看不懂/), r) }
  { const r = LG(row('動作順序', '無（a）', { bad: '' })); ok('--gate：錯誤寫法空白照樣擋', has(r, /錯誤寫法是空的/), r) }
  rmSync(join(t, ledgerFile))

  // ── B. 案子 ──
  const C = join(P, 'AI_Service', 'spec', 'c100')
  const LOGHEAD = '| 輪次 | 退回原因 | 處理類別 | 根因類別 | 錯誤寫法 | 為什麼 | 修正 |\n|---|---|---|---|---|---|---|\n'
  const logOf = (...rs) => '# 退回紀錄\n\n' + LOGHEAD + rs.map(x => `| ${x} | a | 程式錯誤 | 樣本不足 | 名稱只讀 Name 欄 | b | c |\n`).join('')
  const report = (sec51, id = '100') => `# ai-case-report｜#${id} 測試案\n\n## 5. 測試與驗收結果\n\n- x\n\n${sec51}\n## 6. 未盡事項\n\n- 無\n`
  const sec = (n, bad = '名稱只讀 Name 欄') => `### 5.1 退回檢討\n\n- 送驗 ${n + 1} 次、退回 ${n} 次\n\n| 輪次 | 退回原因 | 根因類別 | 錯誤寫法 | 為什麼開發端沒先抓到 | 哪條流程規則擋得住 |\n|---|---|---|---|---|---|\n` + Array.from({ length: n }, (_, i) => `| R${i + 1} | a | 樣本不足 | ${bad} | b | c |\n`).join('') + '\n'
  const setCase = (log, rep) => {
    rmSync(C, { recursive: true, force: true }); mkdirSync(join(C, 'qa'), { recursive: true })
    if (log !== null) writeFileSync(join(C, 'qa', 'rework-log.md'), log)
    if (rep !== null) writeFileSync(join(C, 'ai-case-report.md'), rep)
  }
  const acc = k => check(P, { caseDir: C, stage: 'accept', rejections: k, gate: true })
  setCase(null, null)
  { const r = acc(0); ok('待驗收：歷程退回 0 次、沒有 rework-log ⇒ 過', r.errors.length === 0, r) }
  { const r = acc(2); ok('🔴 待驗收：退回 2 次、沒有 rework-log ⇒ 錯「要先記第 1～2 輪」', has(r, /退回 2 次.*只記了 0 輪.*第 1～2 輪/), r) }
  setCase(logOf('R1', 'R1'), null)
  { const r = acc(2); ok('🔴 待驗收：退回 2 次、rework-log 只有 R1（兩列）⇒ 錯「要先記第 2 輪」', has(r, /只記了 1 輪.*第 2 輪退回/), r) }
  setCase(logOf('R1（11/23）', 'R1', 'R2'), null)
  { const r = acc(2); ok('待驗收：退回 2 次、rework-log R1、R1、R2 ⇒ 過（同輪多列算一輪、輪次後可接日期）', r.errors.length === 0, r) }
  setCase('| 輪次 | 退回原因 | 處理類別 | 根因類別 | 為什麼 | 修正 |\n|---|---|---|---|---|---|\n| R1 | a | 程式錯誤 | 樣本不足 | b | c |\n', null)
  { const r = acc(1); ok('🔴 rework-log 缺「錯誤寫法」欄 ⇒ 錯', has(r, /rework-log\.md 表頭缺「錯誤寫法」欄/), r) }
  setCase(LOGHEAD + '| R1 | a | 程式錯誤 | 樣本不足 |  | b | c |\n', null)
  { const r = acc(1); ok('rework-log 錯誤寫法空白 ⇒ 錯', has(r, /rework-log\.md 第 \d+ 行 錯誤寫法是空的/), r) }
  const LD = (...rows) => w(ledgerFile, HEAD + rows.join(''))
  const done = (o = {}) => check(P, { caseDir: C, stage: 'done', gate: true, ...o })
  setCase(logOf('R1', 'R1', 'R2'), report(sec(3)))
  LD(row('樣本不足', '無（a）'), row('動作順序', '無（b）'), row('修後沒重跑', '無（c）', { r: 'R2' }), row('樣本不足', '無（d）', { id: '#999', date: '2026-12-01' }))
  { const r = done({ id: '100' }); ok('驗收完成：rework-log 3 列、5.1 表 3 列、總帳本案 3 列 ⇒ 過（--gate 不管別案的升級）', r.errors.length === 0, r) }
  { const r = done(); ok('驗收完成：沒給 --id ⇒ 取報告第一行的 #NNN', r.errors.length === 0, r) }
  setCase(logOf('R1', 'R1', 'R2'), report(sec(3).replace(/\| 錯誤寫法 /, '').replace(/\|---\|---\|---\|---\|---\|---\|/, '|---|---|---|---|---|').replace(/\| 名稱只讀 Name 欄 /g, '')))
  { const r = done({ id: '100' }); ok('🔴 驗收完成：5.1 表缺「錯誤寫法」欄 ⇒ 錯', has(r, /5\.1 表格缺「錯誤寫法」欄/), r) }
  setCase(logOf('R1', 'R1', 'R2'), report(''))
  { const r = done({ id: '100' }); ok('🔴 驗收完成：報告沒有 ### 5.1 ⇒ 錯', has(r, /沒有「### 5\.1」/), r) }
  setCase(logOf('R1', 'R1', 'R2'), report(sec(2)))
  { const r = done({ id: '100' }); ok('🔴 驗收完成：5.1 表 2 列 ≠ rework-log 3 列 ⇒ 錯', has(r, /5\.1.*2 列.*rework-log.*3 列/), r) }
  setCase(logOf('R1', 'R1', 'R2'), report(sec(3)))
  LD(row('樣本不足', '無（a）'), row('動作順序', '無（b）'), row('樣本不足', '無（x）', { id: '#999' }))
  { const r = done({ id: '100' }); ok('🔴 驗收完成：總帳本案只有 2 列（別案的列不算）⇒ 錯', has(r, /總帳.*#100.*2 列.*3 列/), r) }
  rmSync(join(t, ledgerFile))
  { const r = done({ id: '100' }); ok('驗收完成：有退回但總帳不存在 ⇒ 錯', has(r, /總帳.*#100.*0 列.*3 列/), r) }
  setCase(null, report('### 5.1 退回檢討\n\n- 送驗 1 次、退回 0 次\n\n'))
  { const r = done({ id: '100' }); ok('驗收完成：沒退回、5.1 寫「退回 0 次」⇒ 過（總帳不用記）', r.errors.length === 0, r) }
  setCase(null, report('### 5.1 退回檢討\n\n（之後補）\n\n'))
  { const r = done({ id: '100' }); ok('🔴 驗收完成：沒退回但 5.1 沒寫「退回 0 次」⇒ 錯', has(r, /退回 0 次/), r) }
  setCase(logOf('R1'), null)
  { const r = done({ id: '100' }); ok('驗收完成：沒有 ai-case-report.md ⇒ 錯', has(r, /找不到.*ai-case-report\.md/), r) }
  setCase(logOf('R1', 'R2'), report(sec(2)))
  LD(row('樣本不足', '無（a）'), row('動作順序', '無（b）', { r: 'R2' }))
  { const r = done({ id: '100', rejections: 3 }); ok('驗收完成也核對歷程退回次數：退回 3 次、只記 2 輪 ⇒ 錯', has(r, /第 3 輪退回/), r) }

  // ── C. 不帶 --case：已結案的案子一起對 ──
  setCase(logOf('R1', 'R2'), report(sec(1)))
  { const r = check(P); ok('--check：案號在總帳的案子 5.1 列數不符 ⇒ 錯', has(r, /c100.*5\.1/), r) }
  setCase(logOf('R1', 'R2'), report('### 5.1 退回檢討（需求方最終驗收後補）\n\n- 送驗 n 次\n\n'))
  rmSync(join(t, ledgerFile))
  { const r = check(P); ok('--check：5.1 還沒填、案號不在總帳（未結案）⇒ 不檢查', r.errors.length === 0, r) }

  // ── CLI ──
  const run = argv => { try { return { code: 0, out: execFileSync(process.execPath, [fileURLToPath(import.meta.url), ...argv], { encoding: 'utf8' }) } } catch (e) { return { code: e.status, out: String(e.stdout) } } }
  setCase(logOf('R1'), null)
  { const x = run(['--check', '--gate', '--case', C, '--stage', 'accept', '--rejections', '2'])
    ok('CLI：--gate --case --stage accept --rejections 2（只記 1 輪）⇒ exit 1、印出要先記第 2 輪', x.code === 1 && /第 2 輪退回/.test(x.out)) }
  { const x = run(['--check', '--gate', '--case', C, '--stage', 'accept', '--rejections', '1']); ok('CLI：退回 1 次、記了 1 輪 ⇒ exit 0', x.code === 0) }
  LD(row('動作順序', '無（a）', { id: '#1' }), row('動作順序', '無（b）', { id: '#2' }))
  { const g = run(['--check', '--gate', '--case', C, '--stage', 'accept', '--rejections', '1']), v = run(['--check', '--root', P])
    ok('🔴 CLI：程式寫法類沒有程式守衛——--gate exit 0、verify（--check）exit 1', g.code === 0 && v.code === 1 && /是程式寫法類/.test(v.out)) }

  rmSync(t, { recursive: true, force: true })
  console.log(fail ? `selftest FAILED: ${fail}` : 'selftest ALL PASSED')
  return fail ? 1 : 0
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const a = process.argv.slice(2)
  const arg = n => { const i = a.indexOf(n); return i >= 0 ? a[i + 1] : undefined }
  if (a.includes('--selftest')) process.exit(selftest())
  const caseDir = arg('--case') ? resolve(arg('--case')) : null
  const findRoot = () => {
    if (caseDir) return findProjectFrom(caseDir)
    let d = here
    for (let i = 0; i < 12; i++) { if (existsSync(join(d, '.claude', 'workflow.json'))) break; const p = dirname(d); if (p === d) { d = null; break } d = p }
    try { return execFileSync('git', ['-C', d ?? here, 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim() } catch { return join(here, '..', '..', '..', '..') }
  }
  const root = resolve(arg('--root') || findRoot())
  const stage = arg('--stage')
  if (caseDir && !['accept', 'done'].includes(stage)) { console.log('❌ --case 要搭配 --stage accept|done'); process.exit(2) }
  const gate = a.includes('--gate')
  const r = check(root, { caseDir, stage, gate, rejections: Number(arg('--rejections') || 0), id: arg('--id') ? normId(arg('--id')) : null })
  if (a.includes('--list')) {
    for (const x of r.rows) console.log(`${x.line}\t${x.date}\t#${x.id}\t${x.round}\t${x.category}\t${x.refs.join('、')}`)
    const n = {}; for (const x of r.rows) n[x.category] = (n[x.category] || 0) + 1
    console.log(`根因類別次數：${Object.entries(n).map(([k, v]) => `${k} ${v}`).join('、') || '（總帳沒有資料）'}`)
  }
  for (const wv of r.warns) console.log(`⚠ ${wv}`)
  const mode = gate ? '（工單閘模式：不查升級）' : ''
  if (r.errors.length) { for (const e of r.errors) console.log(`❌ ${e}`); console.log(`❌ 退回總帳對帳不合格${mode}：${r.errors.length} 處`); process.exit(1) }
  console.log(r.exists ? `✅ 退回總帳對帳合格${mode}：${r.rows.length} 列` : `✅ 退回總帳對帳合格${mode}：尚無總帳（沒有退回紀錄）`)
}
