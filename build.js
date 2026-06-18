// build.js — 把多文件项目打包成单个自包含 HTML(电脑版 + 手机版)
// 用法:node build.js
import { readFileSync, writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const dir = dirname(fileURLToPath(import.meta.url));
const read = p => readFileSync(join(dir, p), 'utf8');
// 去掉 import 行、去掉 export 前缀(单文件里所有定义共享一个作用域)
const strip = s => s.replace(/^\s*import\s.*$/gm, '').replace(/^\s*export\s+/gm, '');

// 依赖顺序拼接;ui.js 里的 AI.xxx 还原成 xxx(命名空间导入已去掉)
const parts = ['src/cards.js', 'src/combos.js', 'src/follow.js', 'src/game.js', 'src/ai.js'].map(p => strip(read(p)));
parts.push(strip(read('src/ui.js')).replace(/\bAI\./g, ''));
const js = parts.join('\n\n');

const styleCss = read('css/style.css');
const mobileCss = read('css/mobile.css');

const appBody = `  <div id="app">
    <header id="topbar">
      <span class="brand">飙分</span>
      <span id="status">—</span>
      <button id="newgame" class="btn ghost">新牌局</button>
    </header>
    <section id="opponents"></section>
    <section id="table">
      <div id="captured" class="empty"></div>
      <div id="trick"></div>
      <div id="message"></div>
    </section>
    <section id="myhand">
      <div id="me-meta"></div>
      <div id="hand"></div>
    </section>
    <section id="actionbar"></section>
  </div>
  <div id="overlay" class="hidden"><div id="dialog"></div></div>`;

const rotateBody = `  <div id="rotate">
    <div class="ico">📱</div>
    <div class="t1">请横屏使用</div>
    <div class="t2">把手机横过来开始游戏</div>
  </div>
`;

const lockScript = `  <script>
    function tryLockLandscape(){ try { screen.orientation && screen.orientation.lock && screen.orientation.lock('landscape').catch(function(){}); } catch(e){} }
    document.addEventListener('click', tryLockLandscape, { once: true });
  </script>`;

const page = ({ title, viewport, css, body }) => `<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="${viewport}">
<title>${title}</title>
<style>
${css}
</style>
</head>
<body>
${body}
<script>
${js}
</script>
</body>
</html>
`;

writeFileSync(join(dir, '飙分-电脑版.html'), page({
  title: '飙分',
  viewport: 'width=device-width, initial-scale=1',
  css: styleCss,
  body: appBody,
}));

writeFileSync(join(dir, '飙分-手机版.html'), page({
  title: '飙分 · 手机版',
  viewport: 'width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no, maximum-scale=1',
  css: styleCss + '\n\n' + mobileCss,
  body: appBody,
}));

console.log('✅ 打包完成:飙分-电脑版.html / 飙分-手机版.html');
