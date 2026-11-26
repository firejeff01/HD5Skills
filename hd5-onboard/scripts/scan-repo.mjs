// scan-repo.mjs — hd5-onboard 的掃描器：只整理「客觀事實」，給 AI 判斷與產生 AGENTS.md 用（2026-11-23）。
//
// 不判斷、不猜業務：輸出的是證據（檔案、指令、計數），推不出來的列在 questions 交給 AI 問使用者。
// 用法：node scan-repo.mjs --root <repo 根> [--project <專案資料夾，相對 repo 根>] [--out <輸出 json>] [--md <輸出 md>]
//       node scan-repo.mjs --selftest
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync, mkdtempSync, mkdirSync, rmSync } from 'node:fs'
import { join, relative, extname, basename, dirname, resolve, posix } from 'node:path'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

const SKIP = new Set(['node_modules', '.git', 'bin', 'obj', 'dist', 'build', 'out', 'target', 'vendor', '.venv', 'venv', '__pycache__',
  '.next', '.nuxt', 'coverage', 'TestResults', '.vs', '.idea', '.vscode', 'wwwroot', 'AI_Service', '.claude', '.agents'])
const LANG = { '.cs': 'C#', '.cshtml': 'Razor', '.razor': 'Razor', '.vue': 'Vue', '.ts': 'TypeScript', '.tsx': 'TypeScript(React)', '.js': 'JavaScript',
  '.jsx': 'JavaScript(React)', '.py': 'Python', '.go': 'Go', '.java': 'Java', '.kt': 'Kotlin', '.rb': 'Ruby', '.php': 'PHP', '.rs': 'Rust',
  '.swift': 'Swift', '.dart': 'Dart', '.sql': 'SQL', '.svelte': 'Svelte', '.scss': 'SCSS', '.css': 'CSS', '.html': 'HTML' }
const MANIFESTS = ['package.json', 'pyproject.toml', 'requirements.txt', 'setup.py', 'Pipfile', 'go.mod', 'pom.xml', 'build.gradle', 'build.gradle.kts',
  'Gemfile', 'composer.json', 'Cargo.toml', 'pubspec.yaml', 'Makefile', 'Dockerfile', 'docker-compose.yml', 'docker-compose.yaml']

const isNestedRepo = p => existsSync(join(p, '.git'))
// packages/：只有 NuGet 快取才跳過（含 .nupkg／.nuspec，或沒有 package.json 且同層有方案檔）；pnpm／yarn workspace 的 packages/* 照常掃（11-23 使用者拍板）
function isNugetPackagesDir(p) {
  let es; try { es = readdirSync(p, { withFileTypes: true }) } catch { return true }
  const nupkg = n => /\.(nupkg|nuspec)$/i.test(n); let pkgJson = es.some(e => e.isFile() && e.name === 'package.json')
  if (es.some(e => e.isFile() && nupkg(e.name))) return true
  for (const e of es.filter(e => e.isDirectory()).slice(0, 60)) {
    let cs; try { cs = readdirSync(join(p, e.name)) } catch { continue }
    if (cs.some(nupkg)) return true; if (cs.includes('package.json')) pkgJson = true
  }
  if (pkgJson) return false
  try { return readdirSync(dirname(p)).some(n => /\.slnx?$/i.test(n)) } catch { return false }
}
function walk(dir, root, acc, depth = 0) {
  if (depth > 14 || acc.files.length > 60000) return
  let es; try { es = readdirSync(dir, { withFileTypes: true }) } catch { return }
  for (const e of es) {
    const p = join(dir, e.name)
    if (e.isDirectory()) {
      if (isNestedRepo(p)) continue   // 子資料夾自己是 git repo／worktree（例 repo 根下的 IMOCore-project2164/）＝別的分支複本，不算本專案
      if (e.name === 'packages' && isNugetPackagesDir(p)) continue
      if (!SKIP.has(e.name) && !e.name.startsWith('.')) walk(p, root, acc, depth + 1); else if (e.name === '.github') walk(p, root, acc, depth + 1)
    }
    else acc.files.push(relative(root, p).split('\\').join('/'))
  }
}
const readJson = p => { try { return JSON.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, '')) } catch { return null } }
const readText = (p, max = 400000) => { try { const s = readFileSync(p, 'utf8'); return s.length > max ? s.slice(0, max) : s } catch { return '' } }
const git = (root, args) => { try { return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() } catch { return '' } }

// 依賴 → 框架（只列有把握的；不在表上的照原名列出依賴給 AI 看）
const NODE_FW = { vue: 'Vue', react: 'React', '@angular/core': 'Angular', next: 'Next.js', nuxt: 'Nuxt', svelte: 'Svelte', vite: 'Vite', express: 'Express',
  '@nestjs/core': 'NestJS', fastify: 'Fastify', vitest: 'Vitest', jest: 'Jest', '@playwright/test': 'Playwright', cypress: 'Cypress', typescript: 'TypeScript', electron: 'Electron' }
const PY_FW = { django: 'Django', fastapi: 'FastAPI', flask: 'Flask', pytest: 'pytest', sqlalchemy: 'SQLAlchemy', celery: 'Celery', pydantic: 'Pydantic' }
const NUGET_FW = [[/Microsoft\.AspNetCore|Sdk="Microsoft\.NET\.Sdk\.Web"/i, 'ASP.NET Core'], [/Microsoft\.EntityFrameworkCore/i, 'EF Core'], [/xunit/i, 'xUnit'],
  [/NUnit/i, 'NUnit'], [/MSTest/i, 'MSTest'], [/SpecFlow|Reqnroll/i, 'SpecFlow/Reqnroll'], [/Microsoft\.Playwright/i, 'Playwright(.NET)'], [/Dapper/i, 'Dapper'], [/Hangfire/i, 'Hangfire']]

const depthOf = w => (w === '.' ? 0 : w.split('/').length)
// 往上找（到 base 為止）：最近的 lockfile 決定套件管理器；package.json 的 packageManager 優先
function pkgManager(base, dir, j) {
  const pmf = String(j.packageManager || '').split('@')[0]; if (['pnpm', 'yarn', 'bun', 'npm'].includes(pmf)) return pmf
  for (let d = dir || '.'; ; d = dirname(d)) {
    const p = join(base, d === '.' ? '' : d)
    if (existsSync(join(p, 'pnpm-lock.yaml')) || existsSync(join(p, 'pnpm-workspace.yaml'))) return 'pnpm'
    if (existsSync(join(p, 'yarn.lock'))) return 'yarn'
    if (existsSync(join(p, 'bun.lockb'))) return 'bun'
    if (existsSync(join(p, 'package-lock.json'))) return 'npm'
    if (d === '.' || dirname(d) === d) return 'npm'
  }
}
// .NET 測試專案：csproj 本身或上層 Directory.Build.props 宣告 IsTestProject，或引用測試框架（11-23 king_wu：測試設定寫在 tests/Directory.Build.props）
function isDotnetTest(base, dir, t) {
  const own = (t.match(/<IsTestProject>\s*(true|false)\s*</i) || [])[1]; if (own) return own.toLowerCase() === 'true'
  if (/xunit|nunit|mstest|Microsoft\.NET\.Test\.Sdk/i.test(t)) return true
  for (let d = dirname(dir || '.'); ; d = dirname(d)) {
    const p = join(base, d === '.' ? '' : d, 'Directory.Build.props')
    if (existsSync(p)) { const v = (readText(p).match(/<IsTestProject>\s*(true|false)\s*</i) || [])[1]; if (v) return v.toLowerCase() === 'true' }
    if (d === '.' || dirname(d) === d) return false
  }
}

// ── 非產品（PoC／範例／技術驗證）判定（11-23 king_wu：pm/saas/技術驗證/arch-poc 的 csproj、slnx、Dapper 被當產品）──
const NONPROD_TOKEN = /^(pocs?|prototypes?|spikes?|sandbox(es)?|examples?|samples?)$/i
const NONPROD_README = /不是產品程式|非產品程式|技術驗證用|僅供技術驗證|僅為技術驗證|this is an? (poc|proof[- ]of[- ]concept)\b|proof[- ]of[- ]concept only|poc only|not production code/i   // 單獨出現 PoC 不算（11-23 使用者拍板）
const segIsNonProd = seg => /技術驗證/.test(seg) || NONPROD_TOKEN.test(seg) || seg.split(/[-_.\s]+/).some(t => NONPROD_TOKEN.test(t))
// 測試資料夾的路徑段（測試支援程式庫判定用；specs 不算：規格檔資料夾不是測試專案）
const isTestSeg = s => /^(tests?|__tests__|e2e)$/i.test(s) || /[._-]tests?$/i.test(s) || /Tests?$/.test(s)
const inTestFolder = dir => !!dir && dir.split('/').some(isTestSeg)
const dirOf = f => (dirname(f) === '.' ? '' : dirname(f))

// 依賴 → 資料庫／基礎設施
const NUGET_DS = [[/^Npgsql/i, 'PostgreSQL'], [/^(Microsoft|System)\.Data\.SqlClient$|EntityFrameworkCore\.SqlServer$/i, 'SQL Server'],
  [/^(MySql\.Data|MySqlConnector|Pomelo\.)/i, 'MySQL'], [/^MongoDB\.Driver/i, 'MongoDB'], [/^StackExchange\.Redis|Caching\.StackExchangeRedis$/i, 'Redis'],
  [/^RabbitMQ\.Client|^MassTransit\.RabbitMQ/i, 'RabbitMQ'], [/^Confluent\.Kafka/i, 'Kafka'], [/^(Elastic\.Clients\.Elasticsearch|NEST|Elasticsearch\.Net)$/i, 'Elasticsearch'],
  [/^Microsoft\.Data\.Sqlite|EntityFrameworkCore\.Sqlite$/i, 'SQLite'],
  [/^Testcontainers\.PostgreSql/i, 'PostgreSQL'], [/^Testcontainers\.MsSql/i, 'SQL Server'], [/^Testcontainers\.(MySql|MariaDb)/i, 'MySQL'],
  [/^Testcontainers\.MongoDb/i, 'MongoDB'], [/^Testcontainers\.Redis/i, 'Redis'], [/^Testcontainers\.RabbitMq/i, 'RabbitMQ'], [/^Testcontainers\.Kafka/i, 'Kafka']]
const NPM_DS = { pg: 'PostgreSQL', 'pg-promise': 'PostgreSQL', postgres: 'PostgreSQL', mysql: 'MySQL', mysql2: 'MySQL', mongodb: 'MongoDB', mongoose: 'MongoDB',
  redis: 'Redis', ioredis: 'Redis', amqplib: 'RabbitMQ', kafkajs: 'Kafka', mssql: 'SQL Server', tedious: 'SQL Server', '@elastic/elasticsearch': 'Elasticsearch' }
const PY_DS = { psycopg: 'PostgreSQL', psycopg2: 'PostgreSQL', 'psycopg2-binary': 'PostgreSQL', asyncpg: 'PostgreSQL', pymysql: 'MySQL', mysqlclient: 'MySQL',
  aiomysql: 'MySQL', redis: 'Redis', pymongo: 'MongoDB', motor: 'MongoDB', pika: 'RabbitMQ', 'aio-pika': 'RabbitMQ', pymssql: 'SQL Server', 'kafka-python': 'Kafka', 'confluent-kafka': 'Kafka' }
const IMAGE_DS = [[/postgres|postgis|timescale/, 'PostgreSQL'], [/mssql|sqlserver|sql-server|azure-sql-edge/, 'SQL Server'], [/mysql/, 'MySQL'], [/mariadb/, 'MariaDB'],
  [/redis|valkey/, 'Redis'], [/mongo/, 'MongoDB'], [/rabbitmq/, 'RabbitMQ'], [/kafka|redpanda/, 'Kafka'], [/elasticsearch|opensearch/, 'Elasticsearch']]
const PRISMA_PROVIDER = { postgresql: 'PostgreSQL', postgres: 'PostgreSQL', mysql: 'MySQL', sqlserver: 'SQL Server', mongodb: 'MongoDB', sqlite: 'SQLite', cockroachdb: 'CockroachDB' }

// 方案檔收錄的專案（.slnx：<Project Path="…"/>；.sln：Project("{…}") = "名", "路徑.csproj", "{…}"），回傳 base 相對、小寫、/ 分隔
function slnProjectPaths(base, f) {
  const t = readText(join(base, f)); const d = dirOf(f) || '.'; const ps = []
  if (/\.slnx$/i.test(f)) for (const m of t.matchAll(/<Project\b[^>]*\bPath\s*=\s*"([^"]+)"/gi)) ps.push(m[1])
  else for (const m of t.matchAll(/^\s*Project\("[^"]*"\)\s*=\s*"[^"]*"\s*,\s*"([^"]+\.(?:cs|fs|vb)proj)"/gim)) ps.push(m[1])
  return ps.map(p => posix.normalize(posix.join(d, p.replace(/\\/g, '/'))).toLowerCase())
}
// 後端根摘要：同一上層資料夾 ≥2 個專案 ⇒「上層/*（n 個專案）」；仍超過 10 筆再往上合一層
function summarizeRoots(dirs) {
  const uniq = [...new Set(dirs)]
  const group = (list, up) => {
    const g = new Map(); for (const x of list) { const k = up(x); if (!g.has(k)) g.set(k, []); g.get(k).push(x) }
    return g
  }
  const lvl1 = group(uniq, d => (d.includes('/') ? posix.dirname(d) : '.'))
  let res = []; for (const [p, ds] of lvl1) { if (p === '.' || ds.length < 2) res.push(...ds.map(d => ({ label: d, n: 1, key: d }))); else res.push({ label: `${p}/*（${ds.length} 個專案）`, n: ds.length, key: p }) }
  if (res.length > 10) {
    const lvl2 = group(res, r => (r.key.includes('/') ? posix.dirname(r.key) : '.')); const r2 = []
    for (const [p, rs] of lvl2) { if (p === '.' || rs.length < 2) r2.push(...rs); else { const n = rs.reduce((a, r) => a + r.n, 0); r2.push({ label: `${p}/**（${n} 個專案，${rs.length} 個子資料夾）`, n, key: p }) } }
    res = r2
  }
  return res.map(r => r.label)
}

// ── BDD：哪些 .feature 真的被測試收錄（11-23 導入 IMOCore：PM 文件 pm/*.feature 被誤報）──
// 收錄來源：.NET 測試／BDD 專案（含上層 Directory.Build.props）的 Include glob、Reqnroll／SpecFlow 預設收錄專案資料夾底下所有 *.feature、
//   測試專案資料夾底下的 .feature；JS 的 cucumber（cucumber.* 設定檔、package.json 的 cucumber.paths，沒設＝預設 features/）、
//   playwright-bdd（features 設定）、jest／vitest-cucumber（loadFeature 路徑）、cypress-cucumber（specPattern）；
//   Python behave（設定檔 paths，沒設＝預設 features/）、pytest-bdd（scenarios()／@scenario 路徑）。解析不到精確路徑就退回該框架的預設資料夾。
const escRe = s => s.replace(/[.+^$()|[\]\\]/g, '\\$&')
export function globRe(g) {
  let s = ''
  for (let i = 0; i < g.length; i++) {
    const c = g[i]
    if (c === '*') { if (g[i + 1] === '*') { i++; if (g[i + 1] === '/') { i++; s += '(?:.*/)?' } else s += '.*' } else s += '[^/]*' }
    else if (c === '?') s += '[^/]'
    else if (c === '{') { const j = g.indexOf('}', i); if (j > i) { s += '(?:' + g.slice(i + 1, j).split(',').map(escRe).join('|') + ')'; i = j } else s += '\\{' }
    else s += escRe(c)
  }
  return new RegExp('^' + s + '$', 'i')
}
// 相對 fromDir 的路徑／glob ⇒ 相對掃描根；跑出掃描範圍（../）或絕對路徑回 null；沒有 glob 也不是 .feature ＝資料夾（底下全部）
function featurePattern(fromDir, p) {
  let q = String(p).trim().replace(/\\/g, '/').replace(/:\d+(:\d+)*$/, '')
  if (!q || /^([A-Za-z]:|\/)/.test(q) || /\$\(|\$\{/.test(q)) return null
  q = posix.normalize(fromDir ? `${fromDir}/${q}` : q).replace(/^\.\//, '')
  if (q === '..' || q.startsWith('../')) return null
  if (q === '.') q = ''
  if (!/[*?{]/.test(q) && !/\.feature$/i.test(q)) q = (q ? q.replace(/\/+$/, '') + '/' : '') + '**/*.feature'
  return q
}
const strLits = s => [...String(s).matchAll(/(['"`])((?:(?!\1)[^\\\n]|\\.)*)\1/g)].map(m => m[2])
export function bddIncludedFeatures(base, files) {
  const feats = files.filter(f => /\.feature$/i.test(f)); if (!feats.length) return []
  const res = [], under = []   // res：glob 正規式；under：資料夾（底下全部 .feature）
  const addPat = (fromDir, p) => { const q = featurePattern(fromDir, p); if (q !== null) res.push(globRe(q)) }
  const has = new Set(files); const at = (dir, n) => (dir ? `${dir}/${n}` : n)
  // .NET
  const DOTNET_BDD =/<PackageReference\b[^>]*\bInclude\s*=\s*"(Reqnroll|SpecFlow|LightBDD|Xunit\.Gherkin)/i
  for (const f of files.filter(f => /\.(csproj|fsproj|vbproj)$/i.test(f))) {
    const dir = dirOf(f), t = readText(join(base, f)), srcs = [{ dir, t }]
    for (let d = dir || '.'; ; d = dirname(d)) {   // 最近的 Directory.Build.props；它再 import 上層的就繼續往上
      const pf = at(d === '.' ? '' : d, 'Directory.Build.props')
      if (has.has(pf)) { const pt = readText(join(base, pf)); srcs.push({ dir: d === '.' ? '' : d, t: pt }); if (!/Directory\.Build\.props/i.test(pt.replace(/<!--[\s\S]*?-->/g, ''))) break }
      if (d === '.' || dirname(d) === d) break
    }
    const all = srcs.map(x => x.t).join('\n')
    if (!DOTNET_BDD.test(all) && !isDotnetTest(base, dir, t)) continue
    under.push(dir)   // 測試專案資料夾底下＝收錄；Reqnroll／SpecFlow 本來就預設收錄專案資料夾下所有 *.feature
    for (const x of srcs) for (const fi of x.t.matchAll(/<(ReqnrollFeatureFiles?|SpecFlowFeatureFiles?|None|Content|EmbeddedResource|AdditionalFiles|Compile)\b[^>]*\bInclude\s*=\s*"([^"]*\.feature[^"]*)"/gi)) {
      for (let inc of fi[2].split(';')) {
        inc = inc.replace(/\$\(MSBuildThisFileDirectory\)/gi, () => (x.dir ? x.dir + '/' : '') + '\u0000').replace(/\$\(MSBuildProjectDirectory\)[\\/]?/gi, '')
        if (inc.includes('\u0000')) { const [d0, rest] = inc.split('\u0000'); addPat('', d0 + rest.replace(/^[\\/]/, '')) } else addPat(dir, inc)
      }
    }
  }
  // JS／Python：依 manifest 所在資料夾
  for (const f of files.filter(f => /(^|\/)(package\.json|pyproject\.toml|requirements[\w.-]*\.txt|Pipfile|setup\.py|setup\.cfg)$/.test(f))) {
    const dir = dirOf(f), b = basename(f)
    if (b === 'package.json') {
      const j = readJson(join(base, f)) || {}; const deps = { ...(j.dependencies || {}), ...(j.devDependencies || {}) }; const k = Object.keys(deps)
      const cfg = n => { const p = at(dir, n); return has.has(p) ? readText(join(base, p), 200000) : null }
      if (k.some(x => x === '@cucumber/cucumber' || x === 'cucumber')) {
        let n = 0
        const pj = j.cucumber; for (const p of [].concat(pj?.paths || [], pj?.default?.paths || [])) { addPat(dir, p); n++ }
        for (const c of ['cucumber.js', 'cucumber.cjs', 'cucumber.mjs', 'cucumber.json', 'cucumber.yaml', 'cucumber.yml']) {
          const t = cfg(c); if (t === null) continue
          for (const m of t.matchAll(/paths["']?\s*:\s*\[([^\]]*)\]/g)) for (const p of strLits(m[1])) { addPat(dir, p); n++ }
          for (const m of t.matchAll(/paths\s*:\s*\r?\n((?:[ \t]*-[ \t]*.+\r?\n?)+)/g)) for (const l of m[1].split(/\r?\n/)) { const p = l.replace(/^\s*-\s*/, '').replace(/^['"]|['"]$/g, '').trim(); if (p) { addPat(dir, p); n++ } }
        }
        if (!n) addPat(dir, 'features')   // cucumber-js 預設 features/**/*.feature
      }
      if (k.includes('playwright-bdd')) {
        let n = 0
        for (const c of ['playwright.config.ts', 'playwright.config.js', 'playwright.config.mjs', 'playwright.config.cjs', 'playwright.config.mts']) {
          const t = cfg(c); if (t === null) continue
          for (const m of t.matchAll(/\bfeatures(?:Root)?\s*:\s*(\[[^\]]*\]|(['"`])(?:(?!\2).)*\2)/g)) for (const p of strLits(m[1])) { addPat(dir, p); n++ }
        }
        if (!n) addPat(dir, 'features')
      }
      if (k.some(x => /^(jest-cucumber|@amiceli\/vitest-cucumber)$/.test(x))) {
        let n = 0
        for (const tf of files.filter(x => (!dir || x.startsWith(dir + '/')) && /\.(test|spec|steps?)\.[cm]?[jt]sx?$/.test(x)).slice(0, 400)) {
          for (const m of readText(join(base, tf), 200000).matchAll(/\bload(?:Feature|Features)\s*\(\s*(['"`])([^'"`]+)\1/g)) { addPat(dir, m[2]); addPat(dirOf(tf), m[2]); n++ }
        }
        if (!n) addPat(dir, 'features')
      }
      if (k.some(x => /cypress-cucumber-preprocessor$/.test(x))) {
        let n = 0
        for (const c of ['cypress.config.ts', 'cypress.config.js', 'cypress.config.mjs', 'cypress.config.cjs']) {
          const t = cfg(c); if (t === null) continue
          for (const m of t.matchAll(/specPattern\s*:\s*(\[[^\]]*\]|(['"`])(?:(?!\2).)*\2)/g)) for (const p of strLits(m[1]).filter(p => /feature/.test(p))) { addPat(dir, p); n++ }
        }
        if (!n) addPat(dir, 'cypress/e2e')
      }
    } else {
      const t = readText(join(base, f)).toLowerCase()
      const cfgText = ['behave.ini', '.behaverc', 'setup.cfg', 'tox.ini', 'pyproject.toml', 'pytest.ini'].map(n => at(dir, n)).filter(p => has.has(p)).map(p => readText(join(base, p), 100000)).join('\n')
      if (/(^|[^a-z0-9_-])behave([^a-z0-9_-]|$)/m.test(t)) {
        const sec = (cfgText.match(/^\[(?:behave|tool\.behave)\]\s*$([\s\S]*?)(?=^\[|(?![\s\S]))/m) || [])[1] || ''
        const pm = sec.match(/^\s*paths\s*=\s*(.*(?:\r?\n[ \t]+.+)*)/m)
        const ps = pm ? (pm[1].includes('[') ? strLits(pm[1]) : pm[1].split(/[\s,]+/).filter(Boolean)) : []
        for (const p of ps) addPat(dir, p)
        if (!ps.length) addPat(dir, 'features')   // behave 預設 features/
      }
      if (/(^|[^a-z0-9_-])pytest-bdd([^a-z0-9_-]|$)/m.test(t)) {
        const bd = (cfgText.match(/^\s*bdd_features_base_dir\s*=\s*['"]?([^'"\r\n]+?)['"]?\s*$/m) || [])[1]
        let n = 0
        for (const pf of files.filter(x => (!dir || x.startsWith(dir + '/')) && /\.py$/.test(x)).slice(0, 2000)) {
          const pt = readText(join(base, pf), 200000); if (!/scenarios?\s*\(/.test(pt)) continue
          for (const m of pt.matchAll(/\bscenarios?\s*\(\s*(['"])([^'"]+)\1/g)) { addPat(bd !== undefined ? (bd.trim() === '.' ? dir : at(dir, bd.trim())) : dirOf(pf), m[2]); n++ }
        }
        if (!n) addPat(dir, 'features')
      }
    }
  }
  const inUnder = f => under.some(d => !d || f.startsWith(d + '/'))
  return feats.filter(f => inUnder(f) || res.some(r => r.test(f)))
}

export function scan(root, projectDir = '') {
  const base = projectDir ? join(root, projectDir) : root
  const acc = { files: [] }; walk(base, base, acc)
  const files = acc.files
  const out = { root, projectDir, scannedFiles: files.length, languages: {}, manifests: [], frameworks: new Set(), commands: [], ci: [], dirs: {},
    frontendRoots: [], backendRoots: [], backendRootsSummary: [], testSupport: [], testDirs: [], routeHints: {}, docs: {}, git: {}, tracker: null,
    datastores: [], excluded: [], missingReferenced: [], candidateTraps: [], questions: [] }
  for (const f of files) { const l = LANG[extname(f).toLowerCase()]; if (l) out.languages[l] = (out.languages[l] || 0) + 1 }
  const top = {}; for (const f of files) { const t = f.includes('/') ? f.split('/')[0] : '(根)'; top[t] = (top[t] || 0) + 1 }
  out.dirs = Object.fromEntries(Object.entries(top).sort((a, b) => b[1] - a[1]).slice(0, 25))

  // 非產品資料夾：路徑段像 PoC／範例，或該資料夾到 repo 根之間（不含根）的 README 前 20 行自稱 PoC／技術驗證
  const readmeByDir = new Map(); for (const f of files) if (/^readme(\.(md|txt|rst))?$/i.test(basename(f))) { const d = dirOf(f); if (!readmeByDir.has(d)) readmeByDir.set(d, f) }
  const npCache = new Map()
  const nonProd = dir => {
    if (!dir) return null; if (npCache.has(dir)) return npCache.get(dir)
    let r = nonProd(dirOf(dir))
    if (!r && segIsNonProd(basename(dir))) r = { path: dir, reason: `路徑段「${basename(dir)}」像 PoC／範例／技術驗證` }
    if (!r && readmeByDir.has(dir)) { const rf = readmeByDir.get(dir); const head = readText(join(base, rf), 20000).split(/\r?\n/).slice(0, 20).join('\n'); if (NONPROD_README.test(head)) r = { path: dir, reason: `${rf} 前 20 行自稱 PoC／技術驗證／不是產品程式` } }
    npCache.set(dir, r); return r
  }
  const excl = new Map(); const addExcluded = (path, reason) => { if (!excl.has(path)) excl.set(path, reason) }
  const prod = f => !nonProd(dirOf(f))
  const prodFiles = files.filter(prod)

  // 方案檔：根目錄有方案檔 ⇒ 巢狀方案檔降級；後端根依（保留的）方案檔收錄的專案為準
  const slnFiles = files.filter(f => /\.slnx?$/i.test(f))
  const rootSln = slnFiles.filter(f => !f.includes('/'))
  const keptSln = slnFiles.filter(f => {
    const np = nonProd(dirOf(f)); if (np) { addExcluded(np.path, np.reason); return false }
    if (f.includes('/') && rootSln.length) { addExcluded(f, '巢狀方案檔（根目錄已有方案檔）'); return false }
    return true
  })
  const slnSet = new Set(keptSln.flatMap(f => slnProjectPaths(base, f)))
  const slnMembers = slnSet.size ? slnSet : null

  const ds = new Map(); const addDs = (name, ev) => { if (!ds.has(name)) ds.set(name, new Set()); if (ds.get(name).size < 5) ds.get(name).add(ev) }
  const tcEvidence = []; const tcDirs = []   // 引用 Testcontainers 的專案（資料夾＝其測試碼的範圍）
  const bddEvidence = [], bddFw = []   // bddFw＝引用 BDD 框架的 manifest；沒有就不報 .feature 陷阱（純文件 .feature）

  for (const f of files) {
    const b = basename(f)
    const isManifest = MANIFESTS.includes(b) || /\.(csproj|fsproj|vbproj|slnx?)$/i.test(b)
    if (!isManifest) continue
    const abs = join(base, f); const dir = dirOf(f)
    const m = { file: f, kind: b }
    const np = nonProd(dir)
    if (np) { addExcluded(np.path, np.reason); m.excluded = np.reason; out.manifests.push(m); continue }
    if (/\.slnx?$/i.test(b) && !keptSln.includes(f)) { m.excluded = excl.get(f) || '巢狀方案檔'; out.manifests.push(m); continue }
    if (b === 'package.json') {
      const j = readJson(abs) || {}; const deps = { ...(j.dependencies || {}), ...(j.devDependencies || {}) }
      m.scripts = j.scripts || {}; m.deps = Object.keys(deps).slice(0, 80)
      for (const [k, v] of Object.entries(NODE_FW)) if (k in deps) out.frameworks.add(v)
      for (const [k, v] of Object.entries(NPM_DS)) if (k in deps) addDs(v, f)
      if ('prisma' in deps || '@prisma/client' in deps) {
        const sch = files.find(x => /(^|\/)schema\.prisma$/.test(x) && (x.startsWith(dir ? dir + '/' : '') || !dir))
        const prov = sch ? (readText(join(base, sch), 100000).match(/provider\s*=\s*"(\w+)"/g) || []).map(x => x.match(/"(\w+)"/)[1]).find(p => PRISMA_PROVIDER[p]) : null
        addDs(prov ? PRISMA_PROVIDER[prov] : 'Prisma（資料庫看 schema.prisma 的 provider）', sch || f)
      }
      if (Object.keys(deps).some(k => /^(@cucumber\/cucumber|cucumber|playwright-bdd|jest-cucumber|@badeball\/cypress-cucumber-preprocessor|cypress-cucumber-preprocessor|@amiceli\/vitest-cucumber)$/.test(k))) bddFw.push(f)
      if (Object.keys(deps).some(k => k === 'testcontainers' || k.startsWith('@testcontainers/'))) { tcEvidence.push(f); tcDirs.push(dir) }
      const ui = ['vue', 'react', '@angular/core', 'svelte', 'next', 'nuxt'].some(k => k in deps)
      if (ui) out.frontendRoots.push(dir || '.')
      const pm = pkgManager(base, dir, j); m.packageManager = pm
      for (const [name, cmd] of Object.entries(m.scripts)) if (/^(build|test|lint|typecheck|type-check|verify|dev|start|e2e|guard)(:|$)/.test(name)) out.commands.push({ where: dir || '.', cmd: `${pm} run ${name}`, raw: String(cmd).slice(0, 160) })
    } else if (/\.(csproj|fsproj|vbproj)$/i.test(b)) {
      if (slnMembers && !slnMembers.has(f.toLowerCase())) {
        // 不在方案檔：不算後端根／框架；但測試專案仍列測試（11-23 使用者拍板）
        const t = readText(abs); m.isTest = isDotnetTest(base, dir, t); m.excluded = '不在方案檔內'
        addExcluded(f, m.isTest ? '不在方案檔內（測試專案：仍列測試，不算框架）' : '不在方案檔內（方案檔沒收錄的專案不算產品）')
        if (m.isTest) { out.testDirs.push(dir || '.'); out.commands.push({ where: dir || '.', cmd: `dotnet test ${f}`, raw: '（不在方案檔）' }); if (/Testcontainers/i.test(t)) { tcEvidence.push(f); tcDirs.push(dir) } }
        out.manifests.push(m); continue
      }
      const t = readText(abs); m.targetFramework = (t.match(/<TargetFrameworks?>([^<]+)</) || [])[1] || null
      m.isTest = isDotnetTest(base, dir, t); m.isWeb = /Sdk="Microsoft\.NET\.Sdk\.Web"|Microsoft\.AspNetCore/i.test(t)
      for (const [re, name] of NUGET_FW) if (re.test(t)) out.frameworks.add(name)
      for (const pr of t.matchAll(/<Package(?:Reference|Version)\b[^>]*\b(?:Include|Update)\s*=\s*"([^"]+)"/gi)) for (const [re, name] of NUGET_DS) if (re.test(pr[1])) addDs(name, f)
      if (/Testcontainers/i.test(t)) { tcEvidence.push(f); tcDirs.push(dir) }
      if (/<PackageReference\b[^>]*\bInclude\s*=\s*"(Reqnroll|SpecFlow|LightBDD|Xunit\.Gherkin)/i.test(t)) bddFw.push(f)
      // BDD：feature 檔從專案外（..）編進測試
      for (const fi of t.matchAll(/<(ReqnrollFeatureFiles?|SpecFlowFeatureFiles?|None|Content|EmbeddedResource|AdditionalFiles|Compile)\b[^>]*\b(?:Include|Update)\s*=\s*"([^"]*\.feature[^"]*)"/gi)) {
        const inc = fi[2].replace(/\\/g, '/'); if (/^\.\.\/|\/\.\.\//.test(inc)) bddEvidence.push(`${f}（${fi[1]} ${inc}）`)
      }
      if (m.isTest) { out.testDirs.push(dir || '.'); out.commands.push({ where: dir || '.', cmd: `dotnet test ${f}`, raw: '' }) }
      else if (inTestFolder(dir)) out.testSupport.push(dir)   // IsTestProject=false 但在測試資料夾＝測試支援程式庫，不是後端根
      else { out.backendRoots.push(dir || '.'); if (m.isWeb) out.commands.push({ where: dir || '.', cmd: `dotnet build ${f}`, raw: '' }) }
      if (/<NoTracking>|QueryTrackingBehavior\.NoTracking/.test(t)) out.candidateTraps.push({ evidence: f, trap: 'EF 查詢預設 NoTracking：改屬性後 SaveChanges 可能不寫回' })
    } else if (/\.slnx?$/i.test(b)) {
      // 方案檔＝整個 .NET 的建置／測試入口（11-23 king_wu 實測：只列各 csproj，真正的方案層入口被截掉）
      out.commands.push({ where: dir || '.', cmd: `dotnet build ${f}`, raw: '', rank: 0 }, { where: dir || '.', cmd: `dotnet test ${f}`, raw: '', rank: 0 })
    } else if (['pyproject.toml', 'requirements.txt', 'Pipfile', 'setup.py'].includes(b)) {
      const t = readText(abs).toLowerCase(); for (const [k, v] of Object.entries(PY_FW)) if (new RegExp(`(^|[^a-z])${k}([^a-z]|$)`, 'm').test(t)) out.frameworks.add(v)
      for (const [k, v] of Object.entries(PY_DS)) if (new RegExp(`(^|[^a-z0-9_-])${k.replace('-', '\\-')}([^a-z0-9_-]|$)`, 'm').test(t)) addDs(v, f)
      if (/(^|[^a-z0-9_-])(behave|pytest-bdd|radish-bdd)([^a-z0-9_-]|$)/m.test(t)) bddFw.push(f)
      if (/(^|[^a-z0-9_-])testcontainers([^a-z0-9_]|$)/m.test(t)) { tcEvidence.push(f); tcDirs.push(dir) }
      out.backendRoots.push(dir || '.'); if (/pytest/.test(t)) out.commands.push({ where: dir || '.', cmd: 'pytest', raw: '' })
    } else if (b === 'go.mod') { out.frameworks.add('Go modules'); out.backendRoots.push(dir || '.'); out.commands.push({ where: dir || '.', cmd: 'go test ./...', raw: '' }) }
    else if (['pom.xml', 'build.gradle', 'build.gradle.kts'].includes(b)) { const t = readText(abs); if (/spring-boot/i.test(t)) out.frameworks.add('Spring Boot'); out.backendRoots.push(dir || '.') }
    else if (b === 'Cargo.toml') { out.frameworks.add('Rust/Cargo'); out.backendRoots.push(dir || '.'); out.commands.push({ where: dir || '.', cmd: 'cargo test', raw: '' }) }
    out.manifests.push(m)
  }
  // 中央套件管理（Directory.Packages.props）與 docker-compose 映像 ⇒ 資料庫／基礎設施
  for (const f of prodFiles) {
    if (/(^|\/)Directory\.Packages\.props$/i.test(f)) { for (const pr of readText(join(base, f)).matchAll(/<PackageVersion\b[^>]*\bInclude\s*=\s*"([^"]+)"/gi)) for (const [re, name] of NUGET_DS) if (re.test(pr[1])) addDs(name, f) }
    else if (/(^|\/)(docker-)?compose[\w.-]*\.ya?ml$/i.test(f)) {
      for (const im of readText(join(base, f), 200000).matchAll(/^\s*image\s*:\s*["']?([^\s"'#]+)/gim)) { const img = im[1].toLowerCase(); for (const [re, name] of IMAGE_DS) if (re.test(img)) addDs(name, `${f}（image ${im[1]}）`) }
    }
  }
  out.datastores = [...ds].map(([name, ev]) => ({ name, evidence: [...ev] })).sort((a, b) => a.name.localeCompare(b.name))
  out.backendRootsSummary = summarizeRoots(out.backendRoots)
  out.testSupport = [...new Set(out.testSupport)]
  // 指令排序：方案檔 → 淺層（repo 根、workspace 根）→ 深層；同一指令只留一筆
  const seen = new Set(); out.commands = out.commands.map((c, i) => ({ ...c, i })).sort((a, b) => (a.rank ?? 1) - (b.rank ?? 1) || depthOf(a.where) - depthOf(b.where) || a.i - b.i)
    .filter(c => { const k = c.where + '|' + c.cmd; if (seen.has(k)) return false; seen.add(k); return true }).map(({ i, rank, ...c }) => c)
  // CI
  for (const f of files.filter(f => /^(azure-pipelines.*\.ya?ml|\.gitlab-ci\.yml|\.github\/workflows\/.*\.ya?ml|Jenkinsfile)$/i.test(f))) {
    const t = readText(join(base, f), 60000)
    const steps = [...t.matchAll(/^\s*(?:-\s*)?(?:script|run|pwsh|powershell|bash)\s*:\s*\|?\s*(.+)$/gim)].map(x => x[1].trim()).filter(s => s && s !== '|').slice(0, 15)
    out.ci.push({ file: f, steps, trigger: (t.match(/^trigger\s*:\s*(.+)$/m) || [])[1] || null })
  }
  // 測試資料夾（名稱慣例；非產品資料夾不算）
  for (const f of prodFiles) { const m = f.match(/^(.*?(?:^|\/)(?:tests?|__tests__|spec|e2e|[\w.]*Tests?))\//i); if (m && !out.testDirs.includes(m[1])) out.testDirs.push(m[1]) }
  out.testDirs = [...new Set(out.testDirs)].slice(0, 30)
  // 路由／頁面線索（給功能地圖骨架）
  const hints = {
    'MVC 控制器（*Controller.cs）': f => /Controller\.cs$/.test(f), 'Razor 頁面／檢視（.cshtml）': f => /\.cshtml$/.test(f),
    'Vue 元件（.vue）': f => /\.vue$/.test(f), 'pages／app 資料夾（Next／Nuxt 檔案路由，或自訂頁面資料夾）': f => /(^|\/)(pages|app)\/.+\.(tsx?|jsx?|vue)$/.test(f) && !/\.(test|spec)\./.test(f),
    '路由設定檔（routes／router）': f => /(^|\/)(routes?|router)(\/|\.)/i.test(f), 'Python 路由（views.py／routers／api）': f => /(views|routers?|api)\.py$|\/routers?\//.test(f),
    'Go handler': f => /handlers?\/.*\.go$|_handler\.go$/.test(f),
  }
  for (const [k, fn] of Object.entries(hints)) { const n = prodFiles.filter(fn); if (n.length) out.routeHints[k] = { count: n.length, sample: n.slice(0, 5) } }
  // 既有文件
  for (const d of ['README.md', 'CLAUDE.md', 'AGENTS.md', '.cursorrules', 'CONTRIBUTING.md', 'docs']) {
    const p = join(root, d); const pp = projectDir ? join(base, d) : null
    if (existsSync(p)) out.docs[d] = d === 'docs' ? 'dir' : `${readText(p).split(/\r?\n/).length} 行（repo 根）`
    else if (pp && existsSync(pp)) out.docs[d] = d === 'docs' ? 'dir' : `${readText(pp).split(/\r?\n/).length} 行（專案資料夾）`
  }
  // 既有的 AI 入口檔：repo 根往下 3 層內所有 CLAUDE.md／AGENTS.md（11-23 實測：只看根會漏掉 IMOCore/AI_Service/AGENTS.md 這份最詳細的）
  out.aiDocs = []
  const findAi = (dir, depth) => {
    if (depth > 3) return
    let es; try { es = readdirSync(dir, { withFileTypes: true }) } catch { return }
    for (const e of es) {
      const p = join(dir, e.name)
      if (e.isDirectory()) { if (isNestedRepo(p)) continue; if (!SKIP.has(e.name) || e.name === 'AI_Service') { if (!e.name.startsWith('.') || e.name === '.claude') findAi(p, depth + 1) } }
      else if (/^(CLAUDE|AGENTS)\.md$/.test(e.name)) out.aiDocs.push({ file: relative(root, p).split('\\').join('/'), lines: readText(p).split(/\r?\n/).length })
    }
  }
  findAi(root, 0)
  out.aiDocs.sort((a, b) => b.lines - a.lines)
  // 候選陷阱：測試碼裡出現連線字串 ⇒ 可能連共用資料庫（11-23 實測：IMOCore 最大的坑掃不出來）
  // 11-23 king_wu：用 Testcontainers 自起容器的被誤報成「連共用資料庫」⇒ 分三類：外部環境／Testcontainers／其他
  const dbTests = [], extTests = [], tcTests = []; let readN = 0
  const LOCAL_HOST = /^(localhost|127\.0\.0\.1|::1|\.|\(local\)|\(localdb\).*|host\.docker\.internal|0\.0\.0\.0)$/i
  const isExternalConn = t => {
    if (/(GetEnvironmentVariable|process\.env|os\.environ|os\.getenv|getenv)\s*[([.]?\s*["'`]?[A-Z0-9_]*(CONNECTION|DATABASE_URL|DB_URL|DB_HOST)/i.test(t)) return true
    const hosts = [...t.matchAll(/(?:^|[;"'\s])(?:Server|Data Source|Host|Address)\s*=\s*([^;"'\s]+)/gim)].map(x => x[1])
      .concat([...t.matchAll(/(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?):\/\/(?:[^@/\s"']*@)?([^:/\s"'?]+)/gi)].map(x => x[1]))
    return hosts.map(h => h.replace(/^tcp:/i, '').split(/[,\\]/)[0]).some(h => h && !LOCAL_HOST.test(h) && !/[{}$<>]/.test(h) && /[.:]/.test(h))   // 沒有點的單字主機（compose 服務名）不算外部
  }
  const inTc = f => tcDirs.some(d => !d || f.startsWith(d + '/'))
  for (const f of prodFiles) {
    if (readN >= 400) break
    if (!/(^|\/)(tests?|__tests__|[\w.]*Tests?)\//i.test(f) || !/\.(cs|py|ts|js|go|java)$/.test(f)) continue
    readN++; const t = readText(join(base, f), 200000)
    const conn = /(Data Source|Server)\s*=|Initial Catalog|ConnectionStrings?|postgres(ql)?:\/\/|mysql:\/\/|mongodb(\+srv)?:\/\//i.test(t)
    const tc = /Testcontainers|ContainerBuilder|(PostgreSql|MsSql|MySql|Redis|MongoDb|RabbitMq)Builder\b/.test(t)
    if (isExternalConn(t)) { if (extTests.length < 5) extTests.push(f) }
    else if (tc || (conn && inTc(f))) { if (tcTests.length < 5) tcTests.push(f) }
    else if (conn && dbTests.length < 5) dbTests.push(f)
  }
  if (tcEvidence.length || tcTests.length) out.candidateTraps.push({ evidence: [...new Set([...tcEvidence.slice(0, 5), ...tcTests])].join('、'), trap: '測試用 Testcontainers 自起容器：要 Docker、首次拉映像慢，不連共用資料庫' })
  if (extTests.length) out.candidateTraps.push({ evidence: extTests.join('、'), trap: '測試碼讀環境變數或寫死外部主機的資料庫連線：這些測試對外部環境跑，可能寫資料——確認哪些測試不能跑、要用什麼 filter' })
  if (dbTests.length) out.candidateTraps.push({ evidence: dbTests.join('、'), trap: '測試碼裡有資料庫連線字串：可能有測試直連共用資料庫，全套跑會寫到共用資料——確認哪些測試不能跑、要用什麼 filter' })
  // BDD：feature 編進測試（csproj 從專案外收 feature，或「確實被測試收錄」的 feature 放在非測試資料夾）
  // 11-23 導入 IMOCore：pm/*.feature 是 PM 文件、沒有任何測試專案收錄，卻被報成會編進測試 ⇒ 只報收錄範圍內的
  const strayFeatures = bddIncludedFeatures(base, prodFiles).filter(f => !inTestFolder(dirOf(f)))
  if (bddFw.length && (bddEvidence.length || strayFeatures.length)) {
    const lists = prodFiles.filter(f => /started|enabled[-_.]?scenarios?/i.test(basename(f))).slice(0, 5)
    out.candidateTraps.push({ evidence: [...bddEvidence.slice(0, 5), ...strayFeatures.slice(0, 5), ...lists.map(l => `情境清單 ${l}`), `BDD 框架 ${bddFw.slice(0, 3).join('、')}`].join('、'),
      trap: '規格檔（.feature）會編進測試：改 feature＝改測試；全綠只代表有收進來的情境' + (lists.length ? '（另有啟用情境清單，沒列進清單的情境不會跑）' : '') })
  }
  // 文件：README、docs/**/*.md（前 200 支、每支前 400KB）⇒ 被參照但不存在的檔、分支命名線索
  const docFiles = prodFiles.filter(f => /(^|\/)readme\.md$/i.test(f) || /(^|\/)docs\/.+\.md$/i.test(f)).sort((a, b) => depthOf(a) - depthOf(b)).slice(0, 200)
  const REF_RE = /([\w./-]*?)(CLAUDE\.md|AGENTS\.md|\.claude\/agents|\.gitattributes|\.gitignore|\.github\/workflows|azure-pipelines(?:[\w.-]*\.ya?ml)?|\.gitlab-ci\.yml)/g
  const rootNames = (() => { try { return readdirSync(root).concat(base !== root ? readdirSync(base) : []) } catch { return [] } })()
  const exists = p => existsSync(join(base, p)) || existsSync(join(root, p))
  const refExists = (pre, tok, docDir) => {
    if (pre) return exists(posix.join(docDir || '.', pre + tok)) || exists(pre + tok)
    if (/^azure-pipelines$/.test(tok)) return rootNames.some(n => /^azure-pipelines/i.test(n))
    if (/^(CLAUDE|AGENTS)\.md$/.test(tok)) return exists(tok) || (out.aiDocs || []).some(d => basename(d.file) === tok)
    return exists(tok) || exists(posix.join(docDir || '.', tok))
  }
  const missing = new Map(); const branchHints = new Map()
  const addHint = (h, ev) => { if (!branchHints.has(h) && branchHints.size < 12) branchHints.set(h, ev) }
  for (const df of docFiles) {
    const lines = readText(join(base, df), 400000).split(/\r?\n/); const docDir = dirOf(df)
    lines.forEach((ln, i) => {
      const ev = `${df}:${i + 1}`
      for (const m of ln.matchAll(REF_RE)) {
        const pre = m[1], tok = m[2]
        if (pre.startsWith('//') || (pre && !pre.endsWith('/'))) continue
        if (/[~$%:\w]$/.test(ln.slice(0, m.index))) continue   // ~/.claude/…、$HOME/…、C:/…＝機器上的路徑，不是 repo 內的檔
        const rootRel = pre.startsWith('/'), p2 = rootRel ? pre.replace(/^\/+/, '') : pre   // / 開頭＝從 repo 根算
        if (!refExists(p2, tok, rootRel ? '' : docDir)) { const k = p2 + tok; if (!missing.has(k)) missing.set(k, []); if (missing.get(k).length < 3) missing.get(k).push(ev) }
      }
      for (const m of ln.matchAll(/(?<![\w/.-])(feature|features|bugfix|hotfix|release|project)([/_])([<{][^>}\s]+[>}]|[\w.*-]+)/gi)) {
        const strong = /^(feature|features|bugfix|hotfix|release)$/i.test(m[1]) && m[2] === '/'
        if (strong || /分支|branch|checkout|git /i.test(ln)) addHint(`${m[1].toLowerCase()}${m[2]}<…>`, ev)
      }
      for (const m of ln.matchAll(/`(main|master|dev|develop|qat|staging)`|\b(main|master|dev|develop|qat|staging)\s*(?:分支|branch)|(?:分支|branch(?:es)?)\s*[:：]?\s*`?(main|master|dev|develop|qat|staging)\b/gi))
        if (/分支|branch|merge|合併|push|checkout|git/i.test(ln)) addHint((m[1] || m[2] || m[3]).toLowerCase(), ev)
    })
  }
  out.missingReferenced = [...missing].map(([ref, evs]) => ({ ref, evidence: evs.join('、') }))
  // git：分支模型、遠端、工單線索
  const remote = git(root, ['remote', 'get-url', 'origin'])
  const allBranches = git(root, ['branch', '-r', '--format=%(refname:short)']).split('\n').filter(Boolean)
  out.git = { remote: remote.replace(/\/\/[^@/]+@/, '//***@'), branchCount: allBranches.length, branches: allBranches.slice(0, 40), head: git(root, ['rev-parse', '--abbrev-ref', 'HEAD']) }
  out.tracker = /dev\.azure\.com|visualstudio\.com|\/_git\//i.test(remote) ? 'azure-devops' : /github\.com/i.test(remote) ? 'github' : remote ? 'unknown' : 'none'
  const bn = allBranches.map(b => b.replace(/^origin\//, ''))   // 從全部分支挑模型（只取前 40 條會漏掉 qat，11-23 實測）
  out.git.model = ['dev', 'qat', 'master', 'main', 'develop', 'staging', 'release'].filter(b => bn.includes(b))
  // git 看不出分支模型 ⇒ 文件裡提到的分支命名當建議（11-23 king_wu：新 repo 只有 main，命名寫在 docs）
  out.git.branchHintsFromDocs = out.git.model.length ? [] : [...branchHints].map(([hint, evidence]) => ({ hint, evidence }))
  out.excluded = [...excl].map(([path, reason]) => ({ path, reason }))
  // 候選陷阱：建置產物被 gitignore
  const gi = readText(join(root, '.gitignore'), 80000)
  const ignoredOut = ['wwwroot/dist', 'dist', 'build', 'out'].filter(d => new RegExp(`(^|\\n)/?[^\\n]*${d.replace('/', '\\/')}/?\\s*(\\n|$)`).test(gi))
  if (ignoredOut.length && out.frontendRoots.length && out.backendRoots.length)   // 只報一次（11-23 實測：同一件事重複四次）
    out.candidateTraps.push({ evidence: '.gitignore', trap: `前端建置產物（${ignoredOut.join('／')}）被 gitignore，但後端發布可能需要它：確認發布流程有先 build 前端` })
  // 推不出來的 → 問使用者
  out.frameworks = [...out.frameworks].sort()
  // 分支命名一律第一題（11-23 使用者：未來要開的分支名稱要在一開始問使用 skills 的人），掃到的分支當建議
  out.questions.push(`分支命名（第一題）：開發分支叫什麼？之後每個案子開的工作分支怎麼命名（前綴，例 feature/<任務>、project_<案號>）？測試、正式分支各是哪一條？AI 可以直接 push 哪些？${out.git.model.length ? `（掃到的分支：${out.git.model.join('、')}）` : out.git.branchHintsFromDocs.length ? `（git 看不出分支模型；文件提到：${out.git.branchHintsFromDocs.map(h => h.hint).join('、')}，可當建議）` : ''}`)
  if (out.missingReferenced.length) out.questions.push(`文件提到但 repo 裡不存在：${out.missingReferenced.map(r => r.ref).join('、')}——是舊的 AI 入口檔／CI 設定遺失（要找回或重建），還是文件過時（要改文件）？`)
  if (!out.commands.some(c => /test/.test(c.cmd))) out.questions.push('找不到測試指令：這個專案怎麼跑測試？哪些測試會連到共用資料庫或外部服務、不能全套跑？')
  if (out.frontendRoots.length && out.backendRoots.length) out.questions.push('前後端都有：畫面改動要先建置前端才會進發布包嗎？發布／部署怎麼做（誰做、做到哪）？')
  if (out.tracker === 'unknown' || out.tracker === 'none') out.questions.push('工單系統：Azure DevOps，還是沒有工單系統（需求用文字建案）？')
  out.questions.push('有沒有「訊號字面意思是錯的」的已知坑（例：某個錯誤其實是檔案鎖、測試全綠其實少跑、某個函式名字像防護其實不做事）？')
  out.questions.push('哪些動作一定要人決定（部署正式環境、寫共用資料、對外通知…）？')
  return out
}

export function toMarkdown(s) {
  const L = []
  L.push(`# 專案掃描結果（hd5-onboard）`, '', `- 掃描位置：${s.projectDir || '（repo 根）'}，檔案 ${s.scannedFiles} 支`)
  L.push(`- 語言：${Object.entries(s.languages).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join('、') || '（無）'}`)
  L.push(`- 框架／工具：${s.frameworks.join('、') || '（看不出來）'}`)
  L.push(`- 後端根：${(s.backendRootsSummary?.length ? s.backendRootsSummary : [...new Set(s.backendRoots)]).join('、') || '—'}｜前端根：${[...new Set(s.frontendRoots)].join('、') || '—'}｜測試：${s.testDirs.slice(0, 8).join('、') || '—'}${s.testSupport?.length ? `｜測試支援：${s.testSupport.slice(0, 8).join('、')}` : ''}`)
  L.push(`- 資料庫／基礎設施：${(s.datastores || []).map(d => d.name).join('、') || '（看不出來）'}`)
  L.push(`- git：${s.git.remote || '（無遠端）'}；分支 ${s.git.model.join('／') || '（看不出模型）'}；工單線索：${s.tracker}`)
  L.push('', '## 指令（候選）', ...s.commands.slice(0, 40).map(c => `- \`${c.cmd}\`（${c.where}）${c.raw ? '：' + c.raw : ''}`))
  if (s.ci.length) L.push('', '## CI', ...s.ci.map(c => `- ${c.file}（trigger：${c.trigger ?? '預設'}）：${c.steps.slice(0, 6).join('；')}`))
  L.push('', '## 路由／頁面線索（功能地圖骨架用）', ...Object.entries(s.routeHints).map(([k, v]) => `- ${k}：${v.count} 支，例 ${v.sample.slice(0, 3).join('、')}`))
  L.push('', '## 目錄（前 25）', ...Object.entries(s.dirs).map(([k, v]) => `- ${k}：${v}`))
  L.push('', '## 既有文件', ...Object.entries(s.docs).map(([k, v]) => `- ${k}：${v}`))
  if (s.aiDocs?.length) L.push('', '## 既有 AI 入口檔（全部要併進新的 AGENTS.md，並寫進既有規則去向表）', ...s.aiDocs.map(d => `- ${d.file}：${d.lines} 行`))
  if (s.datastores?.length) L.push('', '## 資料庫／基礎設施（證據）', ...s.datastores.map(d => `- ${d.name}：${d.evidence.join('、')}`))
  if (s.excluded?.length) L.push('', '## 自動降級（非產品）', '以下不算進後端根／前端根／框架／指令；判錯就請使用者指正。', ...s.excluded.map(e => `- ${e.path}：${e.reason}`))
  if (s.missingReferenced?.length) L.push('', '## 文件提到但不存在', ...s.missingReferenced.map(r => `- ${r.ref}（${r.evidence}）`))
  if (s.git?.branchHintsFromDocs?.length) L.push('', '## 文件裡的分支命名線索', ...s.git.branchHintsFromDocs.map(h => `- ${h.hint}（${h.evidence}）`))
  if (s.candidateTraps.length) L.push('', '## 候選陷阱（要使用者確認）', ...s.candidateTraps.map(t => `- ${t.trap}（證據：${t.evidence}）`))
  L.push('', '## 要問使用者', ...s.questions.map((q, i) => `${i + 1}. ${q}`))
  return L.join('\n') + '\n'
}

const scanImpl = (...a) => scan(...a), toMarkdownImpl = s => toMarkdown(s)
export function selftest(scan = scanImpl, toMarkdown = toMarkdownImpl) {
  const t = mkdtempSync(join(tmpdir(), 'hd5scan_')); let fail = 0
  const w = (p, s) => { mkdirSync(dirname(join(t, p)), { recursive: true }); writeFileSync(join(t, p), s) }
  const ok = (n, c) => { console.log(`  ${c ? 'ok  ' : 'FAIL'} ${n}`); if (!c) fail++ }
  w('api/pyproject.toml', '[project]\ndependencies=["fastapi","sqlalchemy"]\n[tool.pytest]\n'); w('api/app/routers/users.py', 'x'); w('api/tests/test_users.py', 'x')
  w('web/package.json', JSON.stringify({ dependencies: { react: '1' }, devDependencies: { vite: '1', vitest: '1' }, scripts: { build: 'vite build', test: 'vitest', dev: 'vite' } }))
  w('web/src/App.tsx', 'x'); w('web/node_modules/x/index.js', 'x'); w('.gitignore', 'web/dist\n'); w('.github/workflows/ci.yml', 'jobs:\n  t:\n    steps:\n      - run: pytest\n')
  const s = scan(t)
  ok('Python＋TypeScript(React) 都有', s.languages.Python >= 2 && s.languages['TypeScript(React)'] >= 1)
  ok('框架：FastAPI、React、Vite、Vitest、pytest', ['FastAPI', 'React', 'Vite', 'Vitest', 'pytest'].every(f => s.frameworks.includes(f)))
  ok('前端根 web、後端根 api', s.frontendRoots.includes('web') && s.backendRoots.includes('api'))
  ok('指令有 npm run build／test、pytest', ['npm run build', 'npm run test', 'pytest'].every(c => s.commands.some(x => x.cmd === c)))
  ok('node_modules 不掃', !Object.keys(s.dirs).includes('node_modules') && s.scannedFiles < 20)
  ok('CI 抓到 pytest', s.ci.length === 1 && s.ci[0].steps.includes('pytest'))
  ok('路由線索：Python routers', !!s.routeHints['Python 路由（views.py／routers／api）'])
  ok('沒有遠端 ⇒ 工單線索 none、會問工單系統', s.tracker === 'none' && s.questions.some(q => /工單系統/.test(q)))
  ok('前後端都有 ⇒ 會問建置／部署', s.questions.some(q => /建置前端/.test(q)))
  w('svc/Svc.csproj', '<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup><ItemGroup><PackageReference Include="Microsoft.EntityFrameworkCore" /></ItemGroup></Project>')
  w('svc.Tests/Svc.Tests.csproj', '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="xunit" /></ItemGroup></Project>')
  const s2 = scan(t)
  ok('.NET：ASP.NET Core、EF Core、xUnit；測試專案給 dotnet test', ['ASP.NET Core', 'EF Core', 'xUnit'].every(f => s2.frameworks.includes(f)) && s2.commands.some(c => /^dotnet test/.test(c.cmd)))
  ok('Markdown 有「要問使用者」', /## 要問使用者/.test(toMarkdown(s2)))
  ok('第一題一定是分支命名', /^分支命名（第一題）/.test(s2.questions[0]))
  w('App.slnx', '<Solution />'); w('tests/Directory.Build.props', '<Project><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>')
  w('tests/Int.Tests/Int.Tests.csproj', '<Project Sdk="Microsoft.NET.Sdk"></Project>'); w('tests/Specs/Specs.csproj', '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>false</IsTestProject></PropertyGroup></Project>')
  w('fe/package.json', JSON.stringify({ packageManager: 'pnpm@10.0.0', scripts: { test: 'pnpm -r test' } })); w('fe/apps/a/package.json', JSON.stringify({ dependencies: { vue: '3' }, scripts: { test: 'vitest run' } })); w('fe/pnpm-lock.yaml', '')
  const s3 = scan(t)
  ok('方案檔 .slnx ⇒ dotnet build／test 排最前面', s3.commands[0].cmd === 'dotnet build App.slnx' && s3.commands[1].cmd === 'dotnet test App.slnx')
  ok('上層 Directory.Build.props 的 IsTestProject 算測試；自己寫 false 不算測試、在測試資料夾⇒測試支援', s3.commands.some(c => c.cmd === 'dotnet test tests/Int.Tests/Int.Tests.csproj') && !s3.backendRoots.includes('tests/Specs') && (s3.testSupport || []).includes('tests/Specs'))
  ok('pnpm：packageManager 與上層 lockfile 都認得', s3.commands.some(c => c.cmd === 'pnpm run test' && c.where === 'fe') && s3.commands.some(c => c.cmd === 'pnpm run test' && c.where === 'fe/apps/a'))
  ok('npm 專案仍是 npm run', s3.commands.some(c => c.cmd === 'npm run build' && c.where === 'web'))
  ok('空的方案檔（收錄 0 支）⇒ 不套方案檔過濾，svc 仍是後端根', s3.backendRoots.includes('svc'))
  rmSync(t, { recursive: true, force: true })

  // ── king_wu 型：.NET 模組化單體＋PoC 資料夾＋Testcontainers＋BDD＋文件參照（11-23 實測問題 1～7）──
  const k = mkdtempSync(join(tmpdir(), 'hd5scan_k_'))
  const wk = (p, s) => { mkdirSync(dirname(join(k, p)), { recursive: true }); writeFileSync(join(k, p), s) }
  const proj = (sdk, inner = '') => `<Project Sdk="${sdk}"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>${inner}</Project>`
  const ids = ['Domain', 'Application', 'Infrastructure', 'Api', 'Contracts']
  for (const n of ids) wk(`src/Modules/Identity/Identity.${n}/Identity.${n}.csproj`, proj('Microsoft.NET.Sdk'))
  wk('src/Host/Host.csproj', proj('Microsoft.NET.Sdk.Web', '<ItemGroup><PackageReference Include="Npgsql.EntityFrameworkCore.PostgreSQL" /><PackageReference Include="StackExchange.Redis" /></ItemGroup>'))
  wk('src/Worker/Worker.csproj', proj('Microsoft.NET.Sdk'))
  wk('src/Orphan/Orphan.csproj', proj('Microsoft.NET.Sdk', '<ItemGroup><PackageReference Include="Hangfire.Core" /></ItemGroup>'))
  wk('tests/Identity.Tests/Identity.Tests.csproj', proj('Microsoft.NET.Sdk', '<ItemGroup><PackageReference Include="xunit" /><PackageReference Include="Testcontainers.PostgreSql" /><PackageReference Include="Reqnroll.xUnit" /><ReqnrollFeatureFiles Include="..\\..\\specs\\features\\**\\*.feature" /></ItemGroup>'))
  wk('tests/Identity.Tests/DbFixture.cs', 'var c = new PostgreSqlBuilder().Build(); var cs = c.GetConnectionString();')
  wk('tests/Identity.Tests/started-scenarios.txt', 'login')
  wk('tests/Ext.Tests/Ext.Tests.csproj', proj('Microsoft.NET.Sdk', '<ItemGroup><PackageReference Include="xunit" /></ItemGroup>'))
  wk('tests/Ext.Tests/Shared.cs', 'var cs = Environment.GetEnvironmentVariable("APP_DB_CONNECTION") ?? "Server=10.0.0.5;Database=x";')
  wk('tests/Ext.Tests/ComposeHost.cs', 'var cs = "Host=postgres;Username=app;Password=x";')
  wk('tests/Ext.Tests/Domain.cs', 'var cs = "Server=sql.corp.example;Database=x";')
  wk('tests/Loose.Tests/Loose.Tests.csproj', proj('Microsoft.NET.Sdk', '<ItemGroup><PackageReference Include="xunit" /><PackageReference Include="Hangfire.Core" /></ItemGroup>'))
  wk('tests/TestKit/TestKit.csproj', proj('Microsoft.NET.Sdk', '<PropertyGroup><IsTestProject>false</IsTestProject></PropertyGroup>'))
  wk('specs/features/login.feature', 'Feature: login')
  const inSln = [...ids.map(n => `src/Modules/Identity/Identity.${n}/Identity.${n}.csproj`), 'src/Host/Host.csproj', 'tests/Identity.Tests/Identity.Tests.csproj', 'tests/Ext.Tests/Ext.Tests.csproj', 'tests/TestKit/TestKit.csproj']
  wk('App.slnx', `<Solution><Folder Name="/src/">${inSln.map((p, i) => `<Project Path="${i % 2 ? p.split('/').join('\\') : p}" />`).join('')}</Folder></Solution>`)
  wk('Legacy.sln', 'Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Worker", "src\\Worker\\Worker.csproj", "{11111111-1111-1111-1111-111111111111}"\nEndProject\n')
  wk('src/Host/Host.sln', '')
  wk('pm/saas/技術驗證/arch-poc/Poc.csproj', proj('Microsoft.NET.Sdk', '<ItemGroup><PackageReference Include="Dapper" /></ItemGroup>'))
  wk('pm/saas/技術驗證/arch-poc/Poc.slnx', '<Solution><Project Path="Poc.csproj" /></Solution>')
  wk('labs/thing/README.md', '# 實驗\n這是 PoC，不是產品程式\n'); wk('labs/thing/package.json', JSON.stringify({ dependencies: { react: '1', mongoose: '8' }, scripts: { build: 'x' } }))
  wk('examples/demo/package.json', JSON.stringify({ dependencies: { svelte: '1' }, scripts: { dev: 'x' } }))
  wk('web/package.json', JSON.stringify({ dependencies: { vue: '3', ioredis: '5' }, devDependencies: { testcontainers: '10' }, scripts: { test: 'vitest' } }))
  wk('py/requirements.txt', 'fastapi\npymongo>=4\n')
  wk('docker-compose.yml', 'services:\n  mq:\n    image: rabbitmq:3-management\n  db:\n    image: "postgres:16"\n  sql:\n    image: mcr.microsoft.com/mssql/server:2022-latest\n')
  wk('.gitignore', 'bin/\n')
  wk('README.md', '# App\n請先看 CLAUDE.md 與 .claude/agents/ 下的代理。\nCI 設定在 azure-pipelines.yml。\n分支：開 feature/<任務>，合併進 `develop` 分支。\n')
  wk('docs/dev/guide.md', '提交前看 .gitignore；工作分支命名 project_<案號>（git checkout -b）。\n見 https://example.com/x/AGENTS.md\n個人設定 ~/.claude/agents/x.md、/.gitattributes\n')
  const sk = scan(k); const mdk = toMarkdown(sk)
  const ex = sk.excluded || []
  ok('1 PoC：技術驗證／arch-poc 的 csproj 不進後端根、Dapper 不進框架', !sk.backendRoots.some(d => d.includes('arch-poc')) && !sk.frameworks.includes('Dapper') && ex.some(e => e.path === 'pm/saas/技術驗證' || e.path.startsWith('pm/saas/技術驗證')))
  ok('1 PoC：README 自稱 PoC 的資料夾、examples/ 不進前端根與指令', !sk.frontendRoots.includes('labs/thing') && !sk.frontendRoots.includes('examples/demo') && !sk.commands.some(c => /^(labs|examples)/.test(c.where)) && sk.frontendRoots.includes('web'))
  ok('1 巢狀方案檔（根已有方案檔）降級、不出指令', !sk.commands.some(c => /Host\.sln|Poc\.slnx/.test(c.cmd)) && ex.some(e => e.path === 'src/Host/Host.sln'))
  ok('1 scan.md 有「自動降級（非產品）」一節', /## 自動降級（非產品）/.test(mdk))
  ok('2 方案檔為準：不在方案檔的 Orphan 不算後端根（Hangfire 不進框架）；.sln 收錄的 Worker 算', !sk.backendRoots.includes('src/Orphan') && !sk.frameworks.includes('Hangfire') && sk.backendRoots.includes('src/Worker'))
  ok('2 後端根摘要：src/Modules/Identity/*（5 個專案）', (sk.backendRootsSummary || []).includes('src/Modules/Identity/*（5 個專案）') && /src\/Modules\/Identity\/\*（5 個專案）/.test(mdk))
  ok('2 測試資料夾裡 IsTestProject=false ⇒ 測試支援，不是後端根', (sk.testSupport || []).includes('tests/TestKit') && !sk.backendRoots.includes('tests/TestKit'))
  const dsn = (sk.datastores || []).map(d => d.name)
  ok('3 datastores：PostgreSQL、Redis、RabbitMQ、MongoDB、SQL Server（NuGet／npm／Python／compose）', ['PostgreSQL', 'Redis', 'RabbitMQ', 'MongoDB', 'SQL Server'].every(n => dsn.includes(n)) && /- 資料庫／基礎設施：.*PostgreSQL/.test(mdk))
  ok('3 PoC 資料夾的 mongoose 不算證據', !(sk.datastores || []).some(d => d.evidence.some(e => e.startsWith('labs/'))))
  const traps = sk.candidateTraps.map(x => x.trap + '｜' + x.evidence)
  ok('4 Testcontainers ⇒ 報自起容器、不連共用資料庫（DbFixture 不被報成共用 DB）', traps.some(x => /Testcontainers 自起容器/.test(x) && /DbFixture\.cs/.test(x)) && !traps.some(x => /直連共用資料庫/.test(x) && /DbFixture/.test(x)))
  ok('4 讀環境變數／寫死外部主機 ⇒ 報對外部環境跑', traps.some(x => /對外部環境跑，可能寫資料/.test(x) && /Shared\.cs/.test(x)))
  const mr = (sk.missingReferenced || []).map(r => r.ref)
  ok('5 文件提到但不存在：CLAUDE.md、.claude/agents、azure-pipelines.yml（附 檔:行）', ['CLAUDE.md', '.claude/agents', 'azure-pipelines.yml'].every(r => mr.includes(r)) && (sk.missingReferenced || []).some(r => r.ref === 'CLAUDE.md' && /README\.md:2/.test(r.evidence)))
  ok('5 存在的 .gitignore、網址裡的 AGENTS.md、~/ 家目錄路徑不報；/ 開頭當 repo 根；scan.md 有一節＋問使用者', !mr.includes('.gitignore') && !mr.some(r => r.startsWith('/')) && mr.includes('.gitattributes') && !mr.some(r => /AGENTS/.test(r)) && /## 文件提到但不存在/.test(mdk) && sk.questions.some(q => /文件提到但 repo 裡不存在/.test(q)))
  ok('6 BDD：csproj 從 .. 收 feature、feature 在非測試資料夾、started 清單都列出', traps.some(x => /規格檔（\.feature）會編進測試/.test(x) && /Identity\.Tests\.csproj/.test(x) && /specs\/features\/login\.feature/.test(x) && /started-scenarios\.txt/.test(x)))
  const bh = (sk.git?.branchHintsFromDocs || []).map(h => h.hint)
  ok('7 git 沒分支模型 ⇒ 從文件抓 feature/<…>、project_<…>、develop，並帶進第一題', ['feature/<…>', 'project_<…>', 'develop'].every(h => bh.includes(h)) && /文件提到：.*feature\/<…>/.test(sk.questions[0]))
  ok('Windows 路徑一律 /', ![...sk.backendRoots, ...ex.map(e => e.path), ...(sk.missingReferenced || []).map(r => r.evidence)].some(p => p.includes('\\')))
  // 11-23 使用者拍板的五點
  const DT = 'dotnet' + ' test'
  ok('拍板1 不在方案檔的測試專案：仍列 testDirs 與測試指令（註明不在方案檔），不算後端根／框架', sk.testDirs.includes('tests/Loose.Tests') && sk.commands.some(c => c.cmd === `${DT} tests/Loose.Tests/Loose.Tests.csproj` && /不在方案檔/.test(c.raw)) && !sk.backendRoots.includes('tests/Loose.Tests') && !sk.frameworks.includes('Hangfire') && ex.some(e => e.path === 'tests/Loose.Tests/Loose.Tests.csproj'))
  ok('拍板3 單字主機（compose 服務名 postgres）不算外部；含點網域算', traps.some(x => /對外部環境跑/.test(x) && /Domain\.cs/.test(x)) && !traps.some(x => /對外部環境跑/.test(x) && /ComposeHost\.cs/.test(x)))
  rmSync(k, { recursive: true, force: true })

  // 沒有 BDD 框架、README 只提到 PoC、pnpm 的 packages/*、NuGet 快取 packages/
  const n = mkdtempSync(join(tmpdir(), 'hd5scan_n_'))
  const wn = (p, s) => { mkdirSync(dirname(join(n, p)), { recursive: true }); writeFileSync(join(n, p), s) }
  wn('docs/spec/login.feature', 'Feature: login'); wn('app/README.md', '# App\n本模組由 PoC 轉正，現在是正式功能\n')
  wn('app/package.json', JSON.stringify({ dependencies: { react: '1' }, scripts: { build: 'x' } }))
  wn('package.json', JSON.stringify({ packageManager: 'pnpm@10.0.0', scripts: { build: 'pnpm -r build' } })); wn('pnpm-workspace.yaml', 'packages:\n  - packages/*\n')
  wn('packages/ui/package.json', JSON.stringify({ dependencies: { vue: '3' }, scripts: { build: 'vite build' } })); wn('packages/ui/src/A.vue', 'x')
  wn('legacy/Legacy.sln', ''); wn('legacy/packages/Foo.1.0/Foo.1.0.nupkg', 'x'); wn('legacy/packages/Foo.1.0/content/Thing.cs', 'x')
  wn('old/Old.sln', ''); wn('old/packages/Baz/readme.txt', 'x')
  const sn = scan(n)
  ok('拍板2 沒有 BDD 框架 ⇒ 純文件 .feature 不報陷阱', !sn.candidateTraps.some(x => /\.feature/.test(x.trap)))
  ok('拍板4 README 只是提到 PoC（沒明確宣告）⇒ 不降級', sn.frontendRoots.includes('app') && !(sn.excluded || []).some(e => e.path === 'app'))
  ok('拍板5 pnpm 的 packages/* 照常掃（前端根、指令）', sn.frontendRoots.includes('packages/ui') && sn.commands.some(c => c.where === 'packages/ui' && c.cmd === 'pnpm run build'))
  ok('拍板5 NuGet 快取 packages/（含 .nupkg，或無 package.json 且同層有方案檔）仍跳過', !sn.manifests.some(m => /\/packages\//.test(m.file)) && sn.languages['C#'] === undefined && sn.scannedFiles === 9)
  rmSync(n, { recursive: true, force: true })

  // ── .feature 只報「確實被測試收錄」的（11-23 導入 IMOCore：pm/*.feature 是 PM 文件，沒被任何測試專案收錄卻被報）──
  const bdd = files => {
    const d = mkdtempSync(join(tmpdir(), 'hd5scan_b_'))
    for (const [p, s] of Object.entries(files)) { mkdirSync(dirname(join(d, p)), { recursive: true }); writeFileSync(join(d, p), s) }
    const r = scan(d); rmSync(d, { recursive: true, force: true })
    return (r.candidateTraps.find(x => /規格檔（\.feature）會編進測試/.test(x.trap)) || {}).evidence || ''
  }
  const reqn = (inner = '') => proj('Microsoft.NET.Sdk', `<ItemGroup><PackageReference Include="xunit" /><PackageReference Include="Reqnroll.xUnit" />${inner}</ItemGroup>`)
  let ev = bdd({ 'IMO.Tests/IMO.Tests.csproj': reqn(), 'IMO.Tests/Features/a.feature': 'Feature: a', 'pm/req.feature': 'Feature: pm', 'App/App.csproj': proj('Microsoft.NET.Sdk.Web') })
  ok('🔴 .NET：測試專案沒收錄 pm/*.feature（PM 文件）⇒ 不報 .feature 陷阱', !/pm\/req\.feature/.test(ev) && ev === '')
  ev = bdd({ 'IMO.Tests/IMO.Tests.csproj': reqn('<ReqnrollFeatureFiles Include="..\\sa\\**\\*.feature" />'), 'sa/ctx/b.feature': 'Feature: b', 'pm/req.feature': 'Feature: pm', 'docs/c.feature': 'Feature: c' })
  ok('🔴 .NET：csproj Include 收的 sa/ctx/b.feature 報；同 repo 的 pm／docs 不報', /sa\/ctx\/b\.feature/.test(ev) && !/pm\/req\.feature|docs\/c\.feature/.test(ev))
  ev = bdd({ 'test2/Acc/Acc.csproj': proj('Microsoft.NET.Sdk', '<ItemGroup><PackageReference Include="Reqnroll.NUnit" /></ItemGroup>'), 'test2/Directory.Build.props': '<Project><ItemGroup><ReqnrollFeatureFiles Include="$(MSBuildThisFileDirectory)..\\shared-specs\\**\\*.feature" /></ItemGroup></Project>',
    'shared-specs/s.feature': 'Feature: s', 'test2/Acc/Login.feature': 'Feature: l', 'notes/n.feature': 'Feature: n' })
  ok('🔴 .NET：Directory.Build.props 的 $(MSBuildThisFileDirectory) glob、Reqnroll 預設收錄專案資料夾 ⇒ 報；notes 不報', /shared-specs\/s\.feature/.test(ev) && /test2\/Acc\/Login\.feature/.test(ev) && !/notes\/n\.feature/.test(ev))
  ev = bdd({ 'web/package.json': JSON.stringify({ devDependencies: { '@cucumber/cucumber': '10' } }), 'web/cucumber.js': "module.exports = { default: { paths: ['acceptance/**/*.feature'], require: ['steps/**/*.ts'] } }", 'web/acceptance/a.feature': 'Feature: a', 'web/docs/x.feature': 'Feature: x' })
  ok('🔴 JS cucumber.js 的 paths ⇒ 只報 acceptance/，docs 不報', /web\/acceptance\/a\.feature/.test(ev) && !/web\/docs\/x\.feature/.test(ev))
  ev = bdd({ 'app2/package.json': JSON.stringify({ devDependencies: { '@cucumber/cucumber': '10' } }), 'app2/features/f.feature': 'Feature: f', 'app2/notes/n.feature': 'Feature: n' })
  ok('🔴 JS cucumber 沒設定 ⇒ 預設 features/，notes 不報', /app2\/features\/f\.feature/.test(ev) && !/app2\/notes/.test(ev))
  ev = bdd({ 'app3/package.json': JSON.stringify({ devDependencies: { '@cucumber/cucumber': '10' }, cucumber: { paths: ['bdd/'] } }), 'app3/bdd/g.feature': 'Feature: g', 'app3/features/z.feature': 'Feature: z' })
  ok('🔴 JS package.json 的 cucumber.paths ⇒ 報 bdd/、不報沒收的 features/', /app3\/bdd\/g\.feature/.test(ev) && !/app3\/features\/z/.test(ev))
  ev = bdd({ 'pw/package.json': JSON.stringify({ devDependencies: { 'playwright-bdd': '8' } }), 'pw/playwright.config.ts': "const testDir = defineBddConfig({ features: 'specs/*.feature', steps: 'steps/*.ts' })", 'pw/specs/h.feature': 'Feature: h', 'pw/other/i.feature': 'Feature: i' })
  ok('🔴 playwright-bdd 的 features ⇒ 報 specs/，other 不報', /pw\/specs\/h\.feature/.test(ev) && !/pw\/other/.test(ev))
  ev = bdd({ 'py/requirements.txt': 'behave\n', 'py/features/j.feature': 'Feature: j', 'py/docs/k.feature': 'Feature: k' })
  ok('🔴 Python behave 預設 features/ ⇒ 報；docs 不報', /py\/features\/j\.feature/.test(ev) && !/py\/docs/.test(ev))
  ev = bdd({ 'py2/pyproject.toml': '[project]\ndependencies = ["pytest-bdd"]\n', 'py2/tests/test_login.py': 'from pytest_bdd import scenarios\nscenarios("../specs")\n', 'py2/specs/l.feature': 'Feature: l', 'py2/pm/m.feature': 'Feature: m' })
  ok('🔴 pytest-bdd 的 scenarios("../specs")（相對測試檔）⇒ 報 specs/；pm 不報', /py2\/specs\/l\.feature/.test(ev) && !/py2\/pm/.test(ev))
  console.log(fail ? `selftest FAILED: ${fail}` : 'selftest ALL PASSED'); return fail ? 1 : 0
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const a = process.argv.slice(2); const opt = k => { const i = a.indexOf('--' + k); return i >= 0 ? a[i + 1] : undefined }
  if (a.includes('--selftest')) process.exit(selftest())
  const root = resolve(opt('root') ?? '.')
  const s = scan(root, opt('project') ?? '')
  const save = (p, t) => { mkdirSync(dirname(resolve(p)), { recursive: true }); writeFileSync(p, t) }   // 輸出資料夾不存在就建
  if (opt('out')) save(opt('out'), JSON.stringify(s, null, 1))
  const md = toMarkdown(s)
  if (opt('md')) save(opt('md'), md)
  if (!opt('out') && !opt('md')) process.stdout.write(md)
}
