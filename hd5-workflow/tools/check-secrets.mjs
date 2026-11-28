// check-secrets.mjs — 密鑰掃描（2026-11-28；跟程式技術無關、不依賴任何套件）
//
// 為什麼：流程原本只有 QA 強制涵蓋 OWASP Top 10，沒有擋「把密碼、金鑰、權杖寫進程式或設定檔」的機制；
//   這類錯誤一旦 push 就要換密鑰，比寫錯程式貴得多。用掃描工具擋，不靠審查者讀碼時剛好看到。
//
// 掃什麼（高訊號規則，寧可漏掉模糊的，也不要讓誤報多到大家習慣略過）：
//   私鑰區塊、AWS Access Key、GitHub／Slack／Google／Anthropic／OpenAI 權杖、Azure 儲存體 AccountKey、JWT、
//   連線字串裡的 Password=／Pwd=、程式裡把 password／secret／api_key／token 指定成字面字串。
//   值是佔位或變數（${X}、$(X)、{{X}}、<X>、%X%、***、xxx、changeme、example、your_…、env 讀取）不算。
// 怎麼放行：那一行加註解 hd5-allow-secret（例：測試用的假金鑰），並在審查委託檔說明理由。
// 輸出只印遮罩後的片段（前 4 字＋***），不把密鑰原文印進 log。
//
// 用法：node check-secrets.mjs --diff <起點>..<終點> [--root <repo>]   只掃這段 diff 新增的行（獨立驗收前用）
//       node check-secrets.mjs --staged [--root <repo>]               只掃已 stage 的新增行（commit 前用）
//       node check-secrets.mjs --files <檔案…>                        掃整個檔案
//       node check-secrets.mjs --selftest
//       有發現 exit 1，沒有 exit 0，用法錯誤 exit 2
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'

const ALLOW = /hd5-allow-secret/
const PLACEHOLDER = /^(\$\{.*\}|\$\(.*\)|\{\{.*\}\}|<.*>|%.*%|\*+|x{3,}|\.{3,}|-+|changeme|change_me|example.*|sample.*|dummy.*|your[_-].*|test|password|secret|null|none|todo|tbd|env:.*|process\.env.*|os\.environ.*|environment\..*)$/i

export const RULES = [
  { name: '私鑰', re: /-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----/ },
  { name: 'AWS Access Key', re: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { name: 'GitHub 權杖', re: /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b/ },
  { name: 'Slack 權杖', re: /\bxox[abprs]-[A-Za-z0-9-]{10,}\b/ },
  { name: 'Google API Key', re: /\bAIza[0-9A-Za-z_-]{35}\b/ },
  { name: 'Anthropic API Key', re: /\bsk-ant-[A-Za-z0-9_-]{20,}/ },
  { name: 'OpenAI API Key', re: /\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}/ },
  { name: 'Azure 儲存體金鑰', re: /AccountKey=[A-Za-z0-9+/]{40,}={0,2}/ },
  { name: 'JWT', re: /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/ },
  { name: '連線字串密碼', re: /(?:^|[;"'\s])(?:Password|Pwd)\s*=\s*([^;"'\s\u0080-￿]{4,})/i, value: 1 },   // 值只認 ASCII：說明文字裡的「Password=／Pwd=」不算
  { name: '寫死的密碼／金鑰', re: /\b(?:password|passwd|pwd|secret|client[_-]?secret|api[_-]?key|access[_-]?token|auth[_-]?token|private[_-]?key)\b["']?\s*[:=]\s*["']([^"'\s]{8,})["']/i, value: 1 },
]

const mask = s => (s.length <= 4 ? '***' : s.slice(0, 4) + '***')

// 掃一行：回傳 [{ rule, snippet }]
export function scanLine(line) {
  if (ALLOW.test(line)) return []
  const hits = []
  for (const r of RULES) {
    const m = r.re.exec(line)
    if (!m) continue
    const v = r.value ? m[r.value] : m[0]
    if (r.value && (PLACEHOLDER.test(v) || PLACEHOLDER.test(v.replace(/[,;)\]]+$/, '')))) continue
    hits.push({ rule: r.name, snippet: mask(v) })
  }
  return hits
}

// 掃文字：回傳 [{ line, rule, snippet }]（lineNos：只掃這些行號，給 diff 用）
export function scanText(text, lineNos = null) {
  const out = []
  text.replace(/\r\n/g, '\n').split('\n').forEach((l, i) => {
    if (lineNos && !lineNos.has(i + 1)) return
    for (const h of scanLine(l)) out.push({ line: i + 1, ...h })
  })
  return out
}

// 解析 git diff -U0 的新增行：回傳 Map<檔案, [{ line, text }]>
export function addedLines(diff) {
  const files = new Map(); let file = null, ln = 0
  for (const l of diff.replace(/\r\n/g, '\n').split('\n')) {
    if (l.startsWith('+++ ')) { file = l.slice(4).replace(/^b\//, ''); if (file === '/dev/null') file = null; continue }
    const h = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(l)
    if (h) { ln = +h[1]; continue }
    if (!file) continue
    if (l.startsWith('+')) { if (!files.has(file)) files.set(file, []); files.get(file).push({ line: ln, text: l.slice(1) }); ln++ }
    else if (!l.startsWith('-') && !l.startsWith('\\')) ln++
  }
  return files
}
export function scanDiff(diff) {
  const out = []
  for (const [file, lines] of addedLines(diff)) for (const { line, text } of lines) for (const h of scanLine(text)) out.push({ file, line, ...h })
  return out
}

function report(hits, what) {
  if (!hits.length) { console.log(`✅ 密鑰掃描：${what} 沒有發現`); return 0 }
  for (const h of hits) console.log(`❌ ${h.file}:${h.line} ${h.rule}（${h.snippet}）`)
  console.log(`❌ 密鑰掃描：${what} 有 ${hits.length} 處疑似密鑰。改成讀環境變數或密鑰管理服務；已經 push 的要換掉那把密鑰。` +
    `確定是假資料（例：測試用）就在那一行加註解 hd5-allow-secret，並在獨立驗收委託檔說明`)
  return 1
}

export function selftest() {
  let fail = 0
  const ok = (name, c) => { console.log(`  ${c ? 'ok  ' : 'FAIL'} ${name}`); if (!c) fail++ }
  const hit = l => scanLine(l).map(h => h.rule)
  // 都是假值：拆開拼接，避免本檔自己被掃到
  const k = (...p) => p.join('')
  ok('私鑰區塊', hit(k('-----BEGIN RSA ', 'PRIVATE KEY-----')).includes('私鑰'))
  ok('OPENSSH 私鑰', hit(k('-----BEGIN OPENSSH ', 'PRIVATE KEY-----')).includes('私鑰'))
  ok('AWS Access Key', hit(k('aws_key = "AKIA', 'ABCDEFGHIJKLMNOP"')).includes('AWS Access Key'))
  ok('GitHub 權杖', hit(k('token: ghp_', 'a'.repeat(36))).includes('GitHub 權杖'))
  ok('Slack 權杖', hit(k('xoxb-', '1234567890-abcdef')).includes('Slack 權杖'))
  ok('Google API Key', hit(k('AIza', 'S'.repeat(35))).includes('Google API Key'))
  ok('Anthropic API Key', hit(k('key=sk-ant-', 'api03-', 'x'.repeat(30))).includes('Anthropic API Key'))
  ok('Azure 儲存體金鑰', hit(k('DefaultEndpointsProtocol=https;AccountName=a;AccountKey=', 'Q'.repeat(86), '==')).includes('Azure 儲存體金鑰'))
  ok('JWT', hit(k('Bearer eyJ', 'hbGciOiJIUzI1NiJ9', '.eyJ', 'zdWIiOiIxMjM0NTY3ODkwIn0', '.', 'abcdefghijklmnopqrstu')).includes('JWT'))
  ok('連線字串的 Password=', hit(k('Server=db;User Id=sa;Pass', 'word=Hunter2!x;')).includes('連線字串密碼'))
  ok('連線字串的 Pwd=', hit(k('"Data Source=x;Uid=u;Pw', 'd=s3cr3tValue"')).includes('連線字串密碼'))
  ok('程式裡寫死 password', hit(k('const pass', 'word = "Sup3rS3cretValue"')).includes('寫死的密碼／金鑰'))
  ok('JSON 的 "apiKey": "…"', hit(k('"api', 'Key": "a1b2c3d4e5f6g7h8"')).includes('寫死的密碼／金鑰'))
  ok('YAML 的 client_secret: "…"', hit(k('client_sec', 'ret: "abcdefgh12345"')).includes('寫死的密碼／金鑰'))
  // 不該報的
  ok('佔位 ${DB_PASSWORD} 不報', hit(k('Pass', 'word=${DB_PASSWORD};')).length === 0)
  ok('佔位 <填密碼>、*** 不報', hit(k('Pass', 'word=<password>;')).length === 0 && hit(k('pass', 'word = "********"')).length === 0)
  ok('讀環境變數不報', hit(k('const pass', 'word = process.env.DB_PASSWORD')).length === 0)
  ok('changeme／your_api_key 不報', hit(k('pass', 'word: "changeme"')).length === 0 && hit(k('api', '_key = "your_api_key_here"')).length === 0)
  ok('短字串（不到 8 字）不報', hit(k('pass', 'word = "abc"')).length === 0)
  ok('變數名含 password 但不是字面值不報', hit(k('if (user.pass', 'word == input) {')).length === 0)
  ok('一般程式與註解不報', hit('// 密碼由使用者輸入，讀環境變數 APP_TEST_PASSWORD').length === 0 && hit('const tokenCount = tokens.length').length === 0)
  ok('加 hd5-allow-secret 放行', hit(k('const pass', 'word = "Sup3rS3cretValue" // hd5-allow-secret 測試用假值')).length === 0)
  ok('輸出遮罩：不印出密鑰原文', scanLine(k('const pass', 'word = "Sup3rS3cretValue"'))[0].snippet === 'Sup3***')
  // diff 解析：只掃新增行、行號對
  const diff = ['diff --git a/app.cfg b/app.cfg', '--- a/app.cfg', '+++ b/app.cfg', '@@ -1,2 +1,3 @@', ' name=x',
    k('-Pass', 'word=OldSecret1;'), k('+Pass', 'word=NewSecret1;'), '+ok=1', '--- a/gone.txt', '+++ /dev/null', '@@ -1 +0,0 @@', k('-Pass', 'word=Deleted99;')].join('\n')
  const d = scanDiff(diff)
  ok('diff：只報新增行（刪掉的舊密碼不報）、行號＝新檔第 2 行', d.length === 1 && d[0].file === 'app.cfg' && d[0].line === 2)
  // CLI：--files
  const t = mkdtempSync(join(tmpdir(), 'hd5secrets_'))
  const f1 = join(t, 'bad.json'), f2 = join(t, 'good.json')
  writeFileSync(f1, k('{\n  "conn": "Server=x;Pass', 'word=RealOne42;"\n}\n')); writeFileSync(f2, '{\n  "conn": "Server=x;Password=${DB_PWD};"\n}\n')
  const run = argv => { try { return { code: 0, out: execFileSync(process.execPath, [fileURLToPath(import.meta.url), ...argv], { encoding: 'utf8' }) } } catch (e) { return { code: e.status, out: String(e.stdout) } } }
  { const x = run(['--files', f1, f2]); ok('CLI --files：有密鑰 ⇒ exit 1、點名 bad.json:2、不印原文', x.code === 1 && /bad\.json:2 連線字串密碼/.test(x.out) && !/RealOne42/.test(x.out)) }
  { const x = run(['--files', f2]); ok('CLI --files：只有佔位 ⇒ exit 0', x.code === 0) }
  { const x = run([]); ok('CLI 沒給模式 ⇒ exit 2', x.code === 2) }
  { const x = run(['--diff', 'nope1..nope2', '--root', t]); ok('CLI --diff 範圍不存在／不是 git repo ⇒ exit 2、說明原因（不是當機）', x.code === 2 && /git .*失敗/.test(x.out)) }
  rmSync(t, { recursive: true, force: true })
  console.log(fail ? `selftest FAILED: ${fail}` : 'selftest ALL PASSED')
  return fail ? 1 : 0
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const a = process.argv.slice(2)
  const arg = n => { const i = a.indexOf(n); return i >= 0 ? a[i + 1] : undefined }
  if (a.includes('--selftest')) process.exit(selftest())
  const root = resolve(arg('--root') || '.')
  const git = args => {
    try { return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }) }
    catch (e) { console.log(`❌ 密鑰掃描：git ${args.slice(-1)[0]} 失敗（${String(e.stderr || e.message).trim().split('\n')[0]}）——範圍寫錯、commit 不在本機，或不是 git repo`); process.exit(2) }
  }
  if (a.includes('--files')) {
    const files = a.slice(a.indexOf('--files') + 1).filter(x => !x.startsWith('--'))
    const hits = []
    for (const f of files) { let s; try { s = readFileSync(f, 'utf8') } catch { console.log(`⚠ 讀不到 ${f}`); continue } if (s.includes('\u0000')) continue; for (const h of scanText(s)) hits.push({ file: f, ...h }) }
    process.exit(report(hits, `${files.length} 個檔案`))
  }
  if (arg('--diff')) process.exit(report(scanDiff(git(['diff', '-U0', '--no-color', '--no-ext-diff', arg('--diff')])), `diff ${arg('--diff')} 的新增行`))
  if (a.includes('--staged')) process.exit(report(scanDiff(git(['diff', '-U0', '--no-color', '--no-ext-diff', '--cached'])), '已 stage 的新增行'))
  console.log('用法：node check-secrets.mjs --diff <起點>..<終點> | --staged | --files <檔案…> | --selftest [--root <repo>]')
  process.exit(2)
}
