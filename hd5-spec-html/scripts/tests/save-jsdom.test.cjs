// 用 jsdom 實跑產生器 HTML 裡的 saveAnswers()：勾選、填字、按儲存 → 攔截下載內容寫成 _answer.html
const fs = require('fs'); const path = require('path');
const { JSDOM } = require(process.argv[4] || 'jsdom');
const src = process.argv[2], out = process.argv[3];
const html = fs.readFileSync(src, 'utf8');
const dom = new JSDOM(html, { runScripts: 'dangerously' });
const w = dom.window, d = w.document;
let captured = null;
w.alert = (m) => { throw new Error('alert: ' + m); };
w.Blob = class { constructor(parts) { captured = parts.join(''); } };
w.URL.createObjectURL = () => 'blob:test'; w.URL.revokeObjectURL = () => {};
w.HTMLAnchorElement.prototype.click = function () { fs.writeFileSync(out, captured, 'utf8'); console.log('download name=' + this.download + ' bytes=' + Buffer.byteLength(captured)); };
d.getElementById('answeredBy').value = '王小明';
d.querySelector('input[name=q1][value=B]').checked = true;
d.querySelector('textarea[name=q1_note]').value = '第一行\n第二行 <b>';
d.querySelector('input[name=q2][value=A]').checked = true;
d.querySelector('input[name=q2][value=C]').checked = true;
w.saveAnswers();
console.log('answered blocks=' + d.querySelectorAll('.open-question.answered').length + ' banner=' + (d.querySelector('.answered-banner') || {}).textContent + ' saveBar=' + !!d.querySelector('.save-bar'));
