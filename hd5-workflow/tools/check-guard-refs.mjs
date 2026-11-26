// check-guard-refs.mjs — 「守衛：」欄對帳（2026-11-23，吸收中央 IAM P-05）
//
// 為什麼：同一個錯第二次發生就要做成守衛（shared-verification-discipline 第五節），但文字規則跟守衛之間沒有連結——
//   守衛改名或刪掉，文字還說「有守衛」；新加的 🔴 規則也沒人問「它擋得住嗎」。
//
// 檢查兩件事（範圍：repo 根與專案資料夾的 CLAUDE.md／AGENTS.md、AI_Service/AGENTS.md、AI_Service/skills/*.md、.claude/skills/*/SKILL.md、
//   .claude/agents/*.md（代理本文的 🔴 規則，11-23 導入 IMOCore 補）；workflow.json guards.docs 有設就以它為準）：
//   1. 每個 🔴 段落（🔴 那一行起到空行／標題／下一個 🔴 為止；表格列＝那一列）都要有「守衛：」。程式碼區塊內不算。
//   2. 「守衛：」後面的每一項（用「、」分隔，可包反引號）都要對得到：
//        guard:xxx          package.json 的 scripts（專案資料夾，或 guards.packageJson）
//        XxxTests（類別名） 測試資料夾（guards.testDirs，預設 tests/、test/）有 class／def／function／describe XxxTests
//        xxx.ps1／.mjs／.js 腳本檔存在（AI_Service、.claude/hooks、scripts/、tools/，或 guards.scriptRoots）
//        <前綴>xxx          個人常駐 hook：~/.claude/skills/<名>。前綴由 workflow.json guards.personalHooks.prefixes 設（例 ["imo-"]）；
//                           有 repoDir（hook 原始碼在版控）⇒ 版控沒有才錯、本機沒裝只警告；沒有 repoDir ⇒ 本機沒裝只警告（11-24）
//        無（理由）         只能寫文字的規則，理由不可空
//        待辦（G-NN）       AI_Service/spec/guard-backlog.md 要有 G-NN
//      其他寫法（例：「站上關卡 A 表」）一律算錯——要嘛寫守衛名，要嘛寫無（理由）。
//
// 用法：node check-guard-refs.mjs --check [--root <repo 根>]   不合格 exit 1
//       node check-guard-refs.mjs --list  [--root <repo 根>]   列出每條 🔴 與它的守衛
//       node check-guard-refs.mjs --selftest
import { readFileSync, existsSync, readdirSync, statSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { join, dirname, basename, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import { homedir, tmpdir } from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))

export function locate(root) {
  // 專案資料夾（.claude/workflow.json 所在）或舊版 IMOCore 佈局。workflow.json 的 guards 可覆寫：
  //   guards.packageJson（guard:xxx 對 scripts）、guards.testDirs（XxxTests 對 class）、guards.testExtensions、guards.scriptRoots、guards.docs
  let imo = null
  if (existsSync(join(root, 'AI_Service'))) imo = root
  else if (existsSync(join(root, 'IMOCore', 'AI_Service'))) imo = join(root, 'IMOCore')
  else { try { const d = readdirSync(root, { withFileTypes: true }).find(e => e.isDirectory() && existsSync(join(root, e.name, 'AI_Service'))); if (d) imo = join(root, d.name) } catch { } }
  const base = imo || root
  let wf = {}; try { wf = JSON.parse(readFileSync(join(base, '.claude', 'workflow.json'), 'utf8').replace(/^\uFEFF/, '')) } catch { }
  const ai = join(base, wf.paths?.aiService || 'AI_Service')
  const g = wf.guards || {}
  const abs = p => (/^[A-Za-z]:|^\//.test(p) ? p : join(base, p))
  const skillDocs = d => { try { return readdirSync(d, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => join(d, e.name, 'SKILL.md')).filter(p => existsSync(p)).sort() } catch { return [] } }
  const docs = g.docs ? g.docs.map(abs)
    : [join(root, 'CLAUDE.md'), join(root, 'AGENTS.md'), base !== root && join(base, 'CLAUDE.md'), base !== root && join(base, 'AGENTS.md'),
       join(ai, 'AGENTS.md'), ...listMd(join(ai, 'skills')), ...skillDocs(join(base, '.claude', 'skills')), ...listMd(join(base, '.claude', 'agents'))]
  const legacyPkg = imo && join(imo, 'DIMP', 'ClientApp', 'package.json')
  const pkgPath = g.packageJson ? abs(g.packageJson) : [join(base, 'package.json'), legacyPkg].find(p => p && existsSync(p)) || null
  const testDirs = g.testDirs ? g.testDirs.map(abs) : [imo && join(imo, 'IMO.Tests'), join(base, 'tests'), join(base, 'test')].filter(p => p && existsSync(p))
  return {
    ai,
    docs: [...new Set(docs.filter(p => p && existsSync(p)))],
    packageJson: pkgPath,
    testDir: testDirs[0] || null,
    testDirs,
    testExtensions: g.testExtensions || ['.cs', '.ts', '.js', '.py', '.java', '.kt', '.go', '.rb', '.php'],
    scriptRoots: (g.scriptRoots ? g.scriptRoots.map(abs)
      : [ai, join(base, '.claude', 'hooks'), join(base, '.claude', 'skills'), join(base, 'scripts'), join(base, 'tools'), imo && join(imo, 'DIMP', 'ClientApp', 'scripts'), join(root, 'tools')]).filter(p => p && existsSync(p)),
    backlog: join(ai, 'spec', 'guard-backlog.md'),
    // 個人常駐 hook（裝在 ~/.claude/skills/<名>、各人電腦不一定有）：guards.personalHooks = { prefixes: ['imo-'], repoDir?: '相對專案資料夾', install?: '安裝指令說明' }
    personalHooks: {
      prefixes: Array.isArray(g.personalHooks?.prefixes) ? g.personalHooks.prefixes.filter(p => typeof p === 'string' && p) : [],
      repoDir: g.personalHooks?.repoDir ? abs(g.personalHooks.repoDir) : null,
      install: g.personalHooks?.install || null,
    },
  }
}
function listMd(d) { try { return readdirSync(d).filter(f => f.endsWith('.md')).map(f => join(d, f)).sort() } catch { return [] } }
function walk(d, onFile, depth = 0) {
  if (depth > 12) return
  let es; try { es = readdirSync(d, { withFileTypes: true }) } catch { return }
  for (const e of es) {
    if (e.isDirectory()) { if (!/^(node_modules|bin|obj|\.git|dist|TestResults|spec)$/.test(e.name)) walk(join(d, e.name), onFile, depth + 1) }
    else onFile(join(d, e.name), e.name)
  }
}

// ── 抽 🔴 段落 ──
export function extractRules(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  const rules = []
  let fence = false
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i]
    if (/^\s*(```|~~~)/.test(l)) { fence = !fence; continue }
    if (fence || !l.includes('🔴')) continue
    let body = [l]
    // 段落邊界：空行、標題、下一個 🔴、程式碼區塊；條列項目只到下一個同層（或更外層）項目為止，
    // 一般段落遇到條列就停——否則一條 🔴 會吃掉後面不相干的項目（11-23 實測：標註落到別的項目上）
    const isItem = s => /^\s*(>\s*)?([-*+]|\d+[.)])\s/.test(s)
    const indent = s => s.match(/^\s*/)[0].length
    const startItem = isItem(l), ind = indent(l)
    if (!/^\s*\|/.test(l) && !/^\s*#/.test(l)) {
      for (let j = i + 1; j < lines.length && j < i + 15; j++) {
        const n = lines[j]
        if (/^\s*$/.test(n) || /^\s*#/.test(n) || n.includes('🔴') || /^\s*(```|~~~)/.test(n) || /^\s*\|/.test(n)) break
        if (isItem(n) && (!startItem || indent(n) <= ind)) break
        body.push(n)
      }
    }
    rules.push({ line: i + 1, text: body.join('\n') })
  }
  return rules
}
export function parseGuardRefs(text) {
  const out = []
  for (const m of text.matchAll(/守衛[:：]\s*([^\n|]+)/g)) {
    // 括號內的「、」屬於理由，不切；先保護括號
    let s = m[1].trim().replace(/[。；;]\s*$/, '')
    const parts = []; let depth = 0, cur = ''
    for (const ch of s) {
      if (ch === '（' || ch === '(') depth++
      if (ch === '）' || ch === ')') { if (depth === 0) break; depth-- }   // 外層「（守衛：…）」的右括號＝結束
      if (ch === '、' && depth === 0) { parts.push(cur); cur = '' } else cur += ch
    }
    parts.push(cur)
    for (const p of parts) { const t = p.replace(/`/g, '').trim(); if (t) out.push(t) }
  }
  return out
}

// ── 解析守衛名 ──
export function makeResolver(loc, opts = {}) {
  const home = opts.hooksDir ?? join(homedir(), '.claude', 'skills')
  let scripts = null, classes = null, backlog = null, pkg = null
  const lazyScripts = () => { if (!scripts) { scripts = new Set(); for (const r of loc.scriptRoots) walk(r, (_p, n) => scripts.add(n)) } return scripts }
  const lazyClasses = () => {
    if (!classes) {
      classes = new Set()
      for (const d of loc.testDirs || []) if (existsSync(d)) walk(d, (p, n) => { if (loc.testExtensions.some(x => n.endsWith(x))) for (const m of readFileSync(p, 'utf8').matchAll(/\b(?:class|def|function)\s+([A-Za-z_]\w*)|\bdescribe\(\s*['"`]([A-Za-z_]\w*)/g)) classes.add(m[1] || m[2]) })
    }
    return classes
  }
  const lazyBacklog = () => { if (backlog === null) backlog = existsSync(loc.backlog) ? readFileSync(loc.backlog, 'utf8') : ''; return backlog }
  const lazyPkg = () => { if (pkg === null) pkg = loc.packageJson && existsSync(loc.packageJson) ? JSON.parse(readFileSync(loc.packageJson, 'utf8')).scripts ?? {} : undefined; return pkg }
  return function resolveRef(ref) {
    let m
    if ((m = /^無\s*[（(](.*)[）)]$/.exec(ref))) return m[1].trim() ? { ok: true, kind: '無' } : { ok: false, why: '「無（理由）」理由是空的' }
    if ((m = /^待辦\s*[（(]\s*(G-\d+)\s*[）)]$/.exec(ref))) {
      return new RegExp(`(^|[^\\w-])${m[1]}([^\\d]|$)`, 'm').test(lazyBacklog()) ? { ok: true, kind: '待辦' } : { ok: false, why: `guard-backlog.md 沒有 ${m[1]}` }
    }
    if (/^guard:[a-z0-9]+$/.test(ref)) {
      const p = lazyPkg()
      if (p === undefined) return { ok: true, kind: 'npm', warn: '找不到 package.json，未驗證' }
      return ref in p ? { ok: true, kind: 'npm' } : { ok: false, why: `package.json 沒有 ${ref}` }
    }
    const ph = loc.personalHooks || { prefixes: [] }
    if (/^[a-z][a-z0-9-]*$/.test(ref) && ph.prefixes.some(p => ref.startsWith(p))) {
      // 個人 hook 不在每台電腦上——本機沒裝不能算錯（11-24 同事拉 dev 後 45 處紅：Claude Code 會自建 ~/.claude/skills/synced，舊的「沒資料夾才警告」擋不住）。
      // 有 repoDir ⇒ 原始碼在版控，版控裡要有（打錯名才紅）；本機沒裝只提醒安裝。
      const installed = existsSync(join(home, ref))
      const hint = ph.install ? `，安裝：${ph.install}` : ''
      if (ph.repoDir) {
        if (!existsSync(join(ph.repoDir, ref))) return { ok: false, why: `個人 hook ${ref} 不在版控（${ph.repoDir}）` }
        return installed ? { ok: true, kind: 'hook' } : { ok: true, kind: 'hook', warn: `本機沒裝個人 hook ${ref}（版控有）${hint}` }
      }
      return installed ? { ok: true, kind: 'hook' } : { ok: true, kind: 'hook', warn: `本機沒裝個人 hook ${ref}，未驗證${hint}` }
    }
    if (/^[\w.-]+\.(ps1|mjs|js|cjs|py|ts)$/.test(ref)) return lazyScripts().has(ref) ? { ok: true, kind: '腳本' } : { ok: false, why: `找不到腳本 ${ref}` }
    if ((m = /^([A-Z]\w*(?:Tests?|Guard\w*))(?:\.\w+)?$/.exec(ref))) {
      if (!(loc.testDirs || []).length) return { ok: true, kind: '測試', warn: '找不到測試資料夾（workflow.json guards.testDirs），未驗證' }
      return lazyClasses().has(m[1]) ? { ok: true, kind: '測試' } : { ok: false, why: `測試資料夾沒有 ${m[1]}` }
    }
    const hookForm = ph.prefixes.length ? `、${ph.prefixes.map(p => p + 'xxx').join('／')}（個人 hook）` : '（個人 hook 要先在 workflow.json guards.personalHooks.prefixes 設前綴）'
    return { ok: false, why: `看不懂「${ref}」：要寫 guard:xxx、XxxTests、xxx.ps1${hookForm}、無（理由）或 待辦（G-NN）` }
  }
}

export function check(root, opts = {}) {
  const loc = locate(root)
  const resolveRef = makeResolver(loc, opts)
  const errors = [], warns = [], rows = []
  for (const doc of loc.docs) {
    const rel = doc.slice(root.length + 1).replace(/\\/g, '/')
    const text = readFileSync(doc, 'utf8')
    for (const r of extractRules(text)) {
      const refs = parseGuardRefs(r.text)
      rows.push({ where: `${rel}:${r.line}`, refs, head: r.text.split('\n')[0].trim().slice(0, 80) })
      if (refs.length === 0) { errors.push(`${rel}:${r.line} 🔴 規則沒有「守衛：」——${r.text.split('\n')[0].trim().slice(0, 60)}`); continue }
      for (const ref of refs) {
        const v = resolveRef(ref)
        if (!v.ok) errors.push(`${rel}:${r.line} ${v.why}`)
        else if (v.warn) warns.push(`${rel}:${r.line} ${ref}：${v.warn}`)
      }
    }
    // 🔴 段落以外的「守衛：」也要對得到（例：一般規則自願標的）
    const lines = text.replace(/\r\n/g, '\n').split('\n')
    lines.forEach((l, i) => {
      if (l.includes('🔴') || !/守衛[:：]/.test(l)) return
      for (const ref of parseGuardRefs(l)) { const v = resolveRef(ref); if (!v.ok) errors.push(`${rel}:${i + 1} ${v.why}`) }
    })
  }
  return { errors, warns, rows, docs: loc.docs.length }
}

const checkImpl = (...a) => check(...a)
export function selftest(check = checkImpl) {   // 可注入別版 check：拿新測項跑舊程式驗紅
  const t = mkdtempSync(join(tmpdir(), 'guardrefs_'))
  const w = (p, s) => { mkdirSync(dirname(join(t, p)), { recursive: true }); writeFileSync(join(t, p), s) }
  w('IMOCore/DIMP/ClientApp/package.json', JSON.stringify({ scripts: { 'guard:twinrules': 'x' } }))
  w('IMOCore/IMO.Tests/A/FooGuardTests.cs', 'public class FooGuardTests { }')
  w('IMOCore/AI_Service/agent/scripts/workitem-ops.ps1', '')
  w('IMOCore/AI_Service/spec/guard-backlog.md', '| G-01 | x |\n')
  w('hooks/imo-false-signal/x', '')
  w('hooks/synced/x', '')   // Claude Code 自建的資料夾：~/.claude/skills 一定存在（11-24 同事實況）
  const wfBase = JSON.stringify({ guards: { personalHooks: { prefixes: ['imo-'] } } })
  w('IMOCore/.claude/workflow.json', wfBase)
  const doc = (body) => { w('IMOCore/AI_Service/skills/a.md', body); return check(t, { hooksDir: join(t, 'hooks') }) }
  let fail = 0
  const ok = (name, c) => { console.log(`  ${c ? 'ok  ' : 'FAIL'} ${name}`); if (!c) fail++ }
  ok('🔴 沒有守衛 ⇒ 錯', doc('🔴 不要這樣做\n').errors.length === 1)
  ok('同段下一行有守衛 ⇒ 過', doc('🔴 不要這樣做\n說明。守衛：guard:twinrules\n').errors.length === 0)
  ok('空行後的守衛不算同段', doc('🔴 不要這樣做\n\n守衛：guard:twinrules\n').errors.length === 1)
  ok('下一個 🔴 開新段', doc('🔴 A\n🔴 B 守衛：guard:twinrules\n').errors.length === 1)
  ok('表格列：守衛要在同一列', doc('| 🔴 a | b |\n| c | 守衛：guard:twinrules |\n').errors.length === 1)
  ok('程式碼區塊內的 🔴 不算', doc('```\n🔴 範例\n```\n').errors.length === 0)
  ok('npm 守衛不存在 ⇒ 錯', doc('🔴 a 守衛：guard:nope\n').errors.some(e => /package\.json 沒有 guard:nope/.test(e)))
  ok('測試類別、腳本、hook 都認得', doc('🔴 a 守衛：`FooGuardTests`、workitem-ops.ps1、imo-false-signal\n').errors.length === 0)
  ok('測試類別不存在 ⇒ 錯', doc('🔴 a 守衛：BarTests\n').errors.some(e => /沒有 BarTests/.test(e)))
  ok('類別.方法 只比類別', doc('🔴 a 守衛：FooGuardTests.Method1\n').errors.length === 0)
  // ── 個人 hook（11-24：同事沒裝 imo-* 拉 dev 就 45 處紅）──
  { const r = doc('🔴 a 守衛：imo-nope\n')
    ok('個人 hook 本機沒裝（~/.claude/skills 存在）⇒ 只警告、不算錯', r.errors.length === 0 && r.warns.some(x => /imo-nope/.test(x) && /沒裝/.test(x))) }
  w('IMOCore/.claude/workflow.json', JSON.stringify({ guards: { personalHooks: { prefixes: ['imo-'], repoDir: 'AI_Service/mods', install: 'pwsh -File AI_Service/mods/install.ps1' } } }))
  w('IMOCore/AI_Service/mods/imo-inrepo/hooks/hooks.json', '{}')
  { const r = doc('🔴 a 守衛：imo-inrepo\n')
    ok('repoDir：版控有、本機沒裝 ⇒ 過，警告附安裝指令', r.errors.length === 0 && r.warns.some(x => /imo-inrepo/.test(x) && /install\.ps1/.test(x))) }
  ok('repoDir：版控沒有（打錯名）⇒ 錯', doc('🔴 a 守衛：imo-typo\n').errors.some(e => /imo-typo/.test(e) && /不在版控/.test(e)))
  w('IMOCore/AI_Service/mods/imo-false-signal/x', '')
  { const r = doc('🔴 a 守衛：imo-false-signal\n'); ok('repoDir：版控有、本機也有 ⇒ 過且不警告', r.errors.length === 0 && r.warns.length === 0) }
  w('IMOCore/.claude/workflow.json', JSON.stringify({}))
  ok('沒設 personalHooks.prefixes ⇒ imo-xxx 不認得（套件不寫死專案前綴）', doc('🔴 a 守衛：imo-false-signal\n').errors.some(e => /看不懂/.test(e) && /personalHooks/.test(e)))
  w('IMOCore/.claude/workflow.json', wfBase)
  ok('無（理由）過；理由空 ⇒ 錯', doc('🔴 a 守衛：無（要人判斷、機器做不到）\n').errors.length === 0 && doc('🔴 a 守衛：無（）\n').errors.length === 1)
  ok('理由裡的「、」不切開', doc('🔴 a 守衛：無（要看畫面、要比對雛形）\n').errors.length === 0)
  ok('待辦 G-01 在 backlog ⇒ 過；G-99 不在 ⇒ 錯', doc('🔴 a 守衛：待辦（G-01）\n').errors.length === 0 && doc('🔴 a 守衛：待辦（G-99）\n').errors.length === 1)
  ok('看不懂的寫法 ⇒ 錯', doc('🔴 a 守衛：站上關卡 A 表\n').errors.some(e => /看不懂/.test(e)))
  ok('非 🔴 行標的守衛也要對得到', doc('一般規則 守衛：guard:nope\n').errors.length === 1)
  ok('全形冒號與半形冒號都認', doc('🔴 a 守衛:guard:twinrules\n').errors.length === 0)
  ok('包在括號裡「（守衛：…）」：外層右括號不算名稱', doc('🔴 a 說明（守衛：guard:twinrules、無（要人判斷））後面還有字\n').errors.length === 0)
  ok('表格列尾的守衛也認得', doc('| 🔴 a | b 守衛：guard:twinrules |\n').errors.length === 0)
  ok('條列：下一個同層項目的守衛不算', doc('- 🔴 A\n- B 守衛：guard:twinrules\n').errors.length === 1)
  ok('條列：自己的續行與子項目算', doc('- 🔴 A\n  續行\n  - 子項 守衛：guard:twinrules\n').errors.length === 0)
  ok('一般段落：後面緊接的條列不算', doc('🔴 A：\n- B 守衛：guard:twinrules\n').errors.length === 1)
  ok('標題只看標題那一行', doc('## 🔴 標題\n內文 守衛：guard:twinrules\n').errors.length === 1)
  // ── .claude/agents/*.md 也要掃（11-23 導入 IMOCore：代理本文的 🔴 規則沒標守衛抓不到）──
  const chk = () => check(t, { hooksDir: join(t, 'hooks') })
  doc('一般文字\n')
  w('IMOCore/.claude/agents/x-expert.md', '---\nname: x-expert\n---\n🔴 代理裡的規則\n')
  ok('🔴 .claude/agents/*.md 的 🔴 沒守衛 ⇒ 錯（點名代理檔與行號）', chk().errors.some(e => /\.claude\/agents\/x-expert\.md:4 🔴 規則沒有「守衛：」/.test(e)))
  w('IMOCore/.claude/agents/x-expert.md', '---\nname: x-expert\n---\n🔴 代理裡的規則（守衛：guard:twinrules）\n')
  ok('.claude/agents/*.md 有守衛 ⇒ 過', chk().errors.length === 0 && chk().rows.some(x => /x-expert\.md:4/.test(x.where)))
  w('IMOCore/.claude/agents/x-expert.md', '---\nname: x-expert\n---\n🔴 代理裡的規則\n')
  w('IMOCore/.claude/workflow.json', JSON.stringify({ guards: { docs: ['AI_Service/skills/a.md'] } }))
  ok('workflow.json guards.docs 有設 ⇒ 以它為準（不掃代理檔）', chk().errors.length === 0)
  rmSync(join(t, 'IMOCore/.claude/workflow.json'))
  // HD5Skills 自己的代理範本裝進專案後不能一裝就紅（範本裡的 🔴 都要有對得到的守衛）
  const tplDir = join(here, '..', '..', 'hd5-onboard', 'templates', 'agents')
  if (existsSync(tplDir)) {
    rmSync(join(t, 'IMOCore/.claude/agents'), { recursive: true, force: true })
    for (const f of readdirSync(tplDir).filter(f => f.endsWith('.md'))) w(`IMOCore/.claude/agents/${f.replace('.template', '')}`, readFileSync(join(tplDir, f), 'utf8'))
    w('IMOCore/AI_Service/hd5-tools/validate-grill-gate.ps1', ''); w('IMOCore/AI_Service/hd5-tools/verify-map-check.ps1', '')
    const r = chk()
    ok('代理範本（templates/agents）裝進專案 ⇒ 🔴 都有對得到的守衛', r.errors.length === 0 && r.rows.some(x => /\.claude\/agents\//.test(x.where)))
    for (const e of r.errors) console.log(`       ${e}`)
  }
  rmSync(t, { recursive: true, force: true })
  console.log(fail ? `selftest FAILED: ${fail}` : 'selftest ALL PASSED')
  return fail ? 1 : 0
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const a = process.argv.slice(2)
  const ri = a.indexOf('--root')
  // 預設 root：往上找到有 .claude/workflow.json 的專案資料夾所在的 git 根；找不到就用 git 根；再不行退回 IMOCore 舊位置（往上 4 層）
  const findRoot = () => {
    let d = here
    for (let i = 0; i < 12; i++) { if (existsSync(join(d, '.claude', 'workflow.json'))) break; const p = dirname(d); if (p === d) { d = null; break } d = p }
    try { return execFileSync('git', ['-C', d ?? here, 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim() } catch { return join(here, '..', '..', '..', '..') }
  }
  const root = resolve(ri >= 0 ? a[ri + 1] : findRoot())
  if (a.includes('--selftest')) process.exit(selftest())
  const r = check(root)
  if (a.includes('--list')) for (const x of r.rows) console.log(`${x.where}\t${x.refs.join('、') || '（無）'}\t${x.head}`)
  for (const wv of r.warns) console.log(`⚠ ${wv}`)
  if (r.errors.length) { for (const e of r.errors) console.log(`❌ ${e}`); console.log(`❌ 守衛對帳不合格：${r.errors.length} 處（${r.docs} 份文件、${r.rows.length} 條 🔴）`); process.exit(1) }
  console.log(`✅ 守衛對帳合格：${r.docs} 份文件、${r.rows.length} 條 🔴 都有對得到的守衛`)
}
