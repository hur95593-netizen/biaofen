// src/online.js — 联机客户端:WebSocket 连服务器,服务器权威;
// 本地用同一套规则引擎(cards/combos/follow)做出牌预校验与渲染。
import { SUIT_SYMBOL, RANK_LABEL, isJoker, isTrump, sortHand } from './cards.js';
import { detectCombo } from './combos.js';
import { isLegalFollow } from './follow.js';
import { pointValue } from './game.js';

const SUIT_NAME = { S: '黑桃 ♠', H: '红桃 ♥', D: '方块 ♦', C: '梅花 ♣' };
const SUITS = ['S', 'H', 'D', 'C'];
const TRICK_PAUSE = 1400;
const LS_SESSION = 'biaofen-online';   // { room, token, name }
const LS_NICK = 'biaofen-nick';

const $ = id => document.getElementById(id);

let ws = null;
let wsReady = false;
let pendingSend = [];        // 连接建立前排队的消息
let reconnectDelay = 1000;
let intentionalClose = false;

let S = null;                // 服务器最新视图(state)
let me = load(LS_SESSION) || {}; // { room, token, name }
let selected = new Set();
let frozenTrick = null;      // 收墩后定格展示
let prevTricksPlayed = 0;
let prevPhase = '';
let freezeTimer = null;

function load(k) { try { return JSON.parse(localStorage.getItem(k)); } catch { return null; } }
function save(k, v) { localStorage.setItem(k, JSON.stringify(v)); }

// ---------- WebSocket ----------
function connect(onOpen) {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws`);
  ws.onopen = () => {
    wsReady = true;
    reconnectDelay = 1000;
    setConn(true);
    if (onOpen) onOpen();
    for (const m of pendingSend) ws.send(JSON.stringify(m));
    pendingSend = [];
  };
  ws.onmessage = e => handle(JSON.parse(e.data));
  ws.onclose = () => {
    wsReady = false;
    setConn(false);
    if (intentionalClose) { intentionalClose = false; return; }
    // 掉线自动重连(有会话才有意义)
    if (me.room && me.token) {
      toast('连接断开,正在重连…', true);
      setTimeout(() => connect(() => sendJoin()), reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 10000);
    }
  };
}

function send(m) {
  if (wsReady) ws.send(JSON.stringify(m));
  else pendingSend.push(m);
}

function sendJoin() {
  send({ type: 'join', room: me.room, name: me.name || nick(), token: me.token || '' });
}

function setConn(ok) {
  const el = $('conn');
  el.className = 'conn ' + (ok ? 'on' : 'off');
  el.title = ok ? '已连接' : '未连接';
}

// ---------- 服务器消息 ----------
function handle(m) {
  if (m.type === 'joined') {
    me = { room: m.room, token: m.token, name: me.name || nick(), seat: m.seat };
    save(LS_SESSION, me);
    return;
  }
  if (m.type === 'state') return onState(m);
  if (m.type === 'event') return onEvent(m);
  if (m.type === 'error') {
    toast(m.msg, true);
    // 会话失效(房间解散/对局已开始进不去)→ 回到入口
    if (/不存在|已开始|已满/.test(m.msg)) {
      localStorage.removeItem(LS_SESSION);
      me = { name: me.name };
      S = null;
      showEntry();
    }
  }
}

function onState(v) {
  const wasPhase = S ? S.phase : '';
  S = v;
  window.__S = v; // 调试钩子:控制台可查看当前视图
  // 收墩定格:整墩留在桌上(带赢家标记),下一圈有人出牌的状态到达时才清掉
  if (v.tricksPlayed > prevTricksPlayed && v.lastTrick && (!v.trickPlays || !v.trickPlays.length)) {
    frozenTrick = v.lastTrick;
    const isXian = v.lastTrick.winnerSeat !== v.declarer;
    flash(`${seatName(v.lastTrick.winnerSeat)} 收墩` + (isXian && v.lastTrick.points ? `,闲家 +${v.lastTrick.points} 分` : ''));
  } else if (v.trickPlays && v.trickPlays.length) {
    frozenTrick = null;
  }
  if (v.phase === 'done' && frozenTrick) {
    // 最后一墩:亮一拍后放行结算面板
    clearTimeout(freezeTimer);
    freezeTimer = setTimeout(() => { frozenTrick = null; render(); }, TRICK_PAUSE);
  }
  prevTricksPlayed = v.tricksPlayed || 0;
  // 进入扣底阶段:庄家默认选中底牌,方便看清哪些是底牌
  if (v.phase === 'kitty' && wasPhase !== 'kitty' && v.declarer === v.mySeat && v.kittyIds) {
    selected = new Set(v.kittyIds);
  }
  // 手牌变化后清理失效选择
  if (v.hand) {
    const ids = new Set(v.hand.map(c => c.id));
    selected = new Set([...selected].filter(id => ids.has(id)));
  }
  if (v.phase !== 'play' || prevPhase !== 'play') flash('');
  prevPhase = v.phase;
  render();
}

function onEvent(e) {
  if (!S) return;
  const n = i => seatName(i);
  switch (e.kind) {
    case 'joined': toast(`${n(e.seat)} 加入了房间`); break;
    case 'left': toast(`${e.data ?? n(e.seat)} 离开了房间`); break;
    case 'disconnected': toast(`${n(e.seat)} 掉线,AI 托管中`, true); break;
    case 'reconnected': toast(`${n(e.seat)} 回来了`); break;
    case 'bid': toast(e.data ? `${n(e.seat)} 喊 ${e.data}` : `${n(e.seat)} 不喊`); break;
    case 'declarerSet': toast(`${n(e.seat)} 坐庄,喊分 ${e.data}`); break;
    case 'trump': toast(`${n(e.seat)} 亮主 ${SUIT_NAME[e.data] || ''}`); break;
    case 'buried': toast('庄家已扣底'); break;
    case 'result': toast(`本局结束:${e.data}`); break;
  }
}

// ---------- 小部件 ----------
function toast(text, warn = false) {
  const box = $('toasts');
  const d = document.createElement('div');
  d.className = 'toast' + (warn ? ' err' : '');
  d.textContent = text;
  box.appendChild(d);
  setTimeout(() => d.remove(), 2600);
  while (box.children.length > 4) box.firstChild.remove();
}
function flash(msg) { $('message').textContent = msg; }

function nick() {
  return (localStorage.getItem(LS_NICK) || '').slice(0, 12) || '玩家';
}

function seatName(i) {
  if (!S || i == null || i < 0) return '?';
  if (i === S.mySeat) return '你';
  const s = S.seats[i];
  return s && s.taken ? s.name : `${i + 1}号`;
}

function cardEl(card, { small = false } = {}) {
  const d = document.createElement('div');
  const joker = isJoker(card);
  const red = joker ? card.rank === 17 : (card.suit === 'H' || card.suit === 'D');
  d.className = 'card ' + (red ? 'red' : 'black') + (small ? ' small' : '') + (joker ? ' joker' : '');
  d.dataset.id = card.id;
  const r = joker ? (card.rank === 17 ? '大' : '小') : RANK_LABEL[card.rank];
  const s = joker ? '王' : SUIT_SYMBOL[card.suit];
  d.innerHTML = `<span class="idx"><span class="r">${r}</span><span class="s">${s}</span></span><span class="big">${s}</span>`;
  return d;
}
function pile(cards, opts) {
  const w = document.createElement('div');
  w.className = 'cardpile';
  cards.forEach(c => w.appendChild(cardEl(c, opts)));
  return w;
}
function mkBtn(text, on, extra = '') {
  const b = document.createElement('button');
  b.className = 'btn ' + extra;
  b.textContent = text;
  b.onclick = on;
  return b;
}
function hintEl(t) { const d = document.createElement('div'); d.className = 'hint'; d.textContent = t; return d; }
function comboName(c) {
  if (!c) return '';
  if (c.type === 'single') return '单张';
  if (c.type === 'pair') return '对子';
  return `拖拉机（${(c.pairs || c.length / 2)} 连对）`;
}

// ---------- 渲染 ----------
function render() {
  if (!S) return;
  if (!S.started) { renderLobbyOverlay(); return; }
  if (S.phase === 'done' && !frozenTrick) { renderAll(); showResult(); return; }
  hideOverlay();
  renderAll();
}

function renderAll() {
  renderStatus();
  renderOpponents();
  renderTrick();
  renderCaptured();
  renderHand();
  renderActions();
}

function turnSeat() {
  if (!S.started) return -1;
  if (S.phase === 'bidding') return S.bidTurn;
  if (S.phase === 'play') return S.turn;
  if (S.phase === 'declare' || S.phase === 'kitty') return S.declarer;
  return -1;
}
function roleTag(seat) {
  if (S.declarer == null || S.declarer < 0) return '';
  return seat === S.declarer ? '庄' : '闲';
}

function renderStatus() {
  const parts = [`房 ${S.room}`];
  if (S.handNo) parts.push(`第 ${S.handNo} 局`);
  if (S.trumpSuit) parts.push(`主：${SUIT_NAME[S.trumpSuit]}`);
  if (S.contract) parts.push(`喊分 ${S.contract}（线 ${200 - S.contract}）`);
  if (S.declarer >= 0) parts.push(`庄：${seatName(S.declarer)}`);
  if (S.phase === 'play') parts.push(`闲家已捡 ${S.xianPoints} 分`);
  $('status').textContent = parts.join('　·　');
}

function renderOpponents() {
  const box = $('opponents');
  box.innerHTML = '';
  for (let k = 1; k < S.players; k++) {
    const s = (S.mySeat + k) % S.players; // 从我的下家起顺时针排
    const seat = S.seats[s];
    const o = document.createElement('div');
    o.className = 'opp' + (turnSeat() === s ? ' turn' : '');
    const isZ = S.declarer === s;
    const dot = seat.bot ? '🤖' : (seat.connected ? '' : '⚠️离线');
    o.innerHTML =
      `<div class="name">${seatName(s)} ${dot}<span class="role ${isZ ? 'zhuang' : ''}">${roleTag(s) || '—'}</span></div>
       <div class="count">手牌 ${S.counts ? S.counts[s] : '—'} 张　积分 ${S.scores[s]}</div>`;
    box.appendChild(o);
  }
}

function renderTrick() {
  const t = $('trick');
  t.innerHTML = '';
  const show = frozenTrick ? frozenTrick.plays : S.trickPlays;
  const winnerSeat = frozenTrick ? frozenTrick.winnerSeat : -1;
  if (!show || !show.length) {
    if (S.phase === 'play')
      t.innerHTML = `<div class="trickplay"><div class="who turnwho">${seatName(turnSeat())}<i>${roleTag(turnSeat())}</i> 出牌…</div></div>`;
    else if (S.phase === 'bidding')
      t.innerHTML = `<div class="trickplay"><div class="who turnwho">${seatName(S.bidTurn)} 喊分中…</div></div>`;
    else if (S.phase === 'declare')
      t.innerHTML = `<div class="trickplay"><div class="who turnwho">${seatName(S.declarer)} 亮主中…</div></div>`;
    else if (S.phase === 'kitty')
      t.innerHTML = `<div class="trickplay"><div class="who turnwho">${seatName(S.declarer)} 扣底中…</div></div>`;
    return;
  }
  for (const p of show) {
    const isZ = p.seat === S.declarer;
    const col = document.createElement('div');
    col.className = 'trickplay' + (p.seat === winnerSeat ? ' win' : '') + (isZ ? ' zhuangplay' : '');
    const who = document.createElement('div');
    who.className = 'who';
    who.innerHTML = `${seatName(p.seat)}<i class="${isZ ? 'z' : 'x'}">${roleTag(p.seat)}</i>` + (p.seat === winnerSeat ? ' ✓收墩' : '');
    const cards = pile(p.cards, { small: true });
    cards.className = 'cards';
    col.appendChild(who);
    col.appendChild(cards);
    t.appendChild(col);
  }
}

function renderCaptured() {
  const box = $('captured');
  const caps = S.xianCaptured || [];
  const active = (S.phase === 'play' || S.phase === 'done') && caps.length;
  box.className = active ? '' : 'empty';
  box.innerHTML = '';
  if (!active) return;
  const label = document.createElement('span');
  label.className = 'cap-label';
  label.textContent = `闲家捡分 ${S.xianPoints}`;
  const strip = pile(caps.slice().sort((a, b) => pointValue(b) - pointValue(a) || b.rank - a.rank), { small: true });
  strip.className = 'cap-cards';
  box.appendChild(label);
  box.appendChild(strip);
}

function renderHand() {
  const meta = $('me-meta');
  const isZ = S.declarer === S.mySeat;
  meta.innerHTML = `<span class="role ${isZ ? 'zhuang' : ''}">${S.declarer < 0 ? '—' : (isZ ? '庄家' : '闲家')}</span>
    <b>你（${me.name || ''}）</b>　积分 ${S.scores[S.mySeat]}　手牌 ${S.hand ? S.hand.length : 0} 张`;

  const h = $('hand');
  h.innerHTML = '';
  if (!S.hand) return;
  const sorted = sortHand(S.hand, S.trumpSuit || '_');
  const myTurn = (S.phase === 'play' && S.turn === S.mySeat) || (S.phase === 'kitty' && S.declarer === S.mySeat);
  for (const c of sorted) {
    const e = cardEl(c);
    if (S.trumpSuit && isTrump(c, S.trumpSuit)) e.classList.add('trump');
    if (selected.has(c.id)) e.classList.add('sel');
    if (myTurn) e.onclick = () => toggleCard(c.id);
    else e.classList.add('dim');
    h.appendChild(e);
  }
}

function toggleCard(id) {
  if (selected.has(id)) selected.delete(id);
  else selected.add(id);
  renderHand();
  renderActions();
}
function selectedCards() { return (S.hand || []).filter(c => selected.has(c.id)); }

function renderActions() {
  const bar = $('actionbar');
  bar.innerHTML = '';
  if (!S || !S.started) return;
  if (S.phase === 'bidding' && S.bidTurn === S.mySeat) return renderBidActions(bar);
  if (S.phase === 'declare' && S.declarer === S.mySeat) return renderDeclareActions(bar);
  if (S.phase === 'kitty' && S.declarer === S.mySeat) return renderKittyActions(bar);
  if (S.phase === 'play' && S.turn === S.mySeat) return renderPlayActions(bar);
  const ts = turnSeat();
  const waiting = S.phase === 'done' ? '' : (ts >= 0 ? `等待 ${seatName(ts)} …` : '');
  bar.innerHTML = `<div class="hint">${waiting}</div>`;
}

function renderBidActions(bar) {
  const hint = document.createElement('div');
  hint.className = 'hint';
  hint.textContent = S.highBid ? `当前最高喊分 ${S.highBid}（${seatName(S.highBidder)}）` : '你先喊分（100 起,10 的倍数;最高者坐庄）';
  bar.appendChild(hint);
  const lv = S.nextBidLevel;
  for (const amt of [lv, lv + 10, lv + 20]) {
    if (amt > 200) break;
    bar.appendChild(mkBtn(`喊 ${amt}`, () => send({ type: 'bid', amount: amt })));
  }
  // 任意跳喊:更高档位一键直达
  if (lv + 30 <= 200) {
    const sel = document.createElement('select');
    sel.className = 'btn';
    for (let amt = lv + 30; amt <= 200; amt += 10) {
      const o = document.createElement('option');
      o.value = amt; o.textContent = `喊 ${amt}`;
      sel.appendChild(o);
    }
    sel.onchange = () => send({ type: 'bid', amount: +sel.value });
    bar.appendChild(sel);
  }
  bar.appendChild(mkBtn('不喊', () => send({ type: 'bid', amount: 0 }), 'ghost'));
}

function renderDeclareActions(bar) {
  bar.appendChild(hintEl('你坐庄,选一门花色当主（王/3/2 永远是主）'));
  for (const s of SUITS) {
    const b = mkBtn(SUIT_SYMBOL[s], () => send({ type: 'trump', suit: s }));
    b.className = 'btn suitbtn' + (s === 'H' || s === 'D' ? ' red' : '');
    bar.appendChild(b);
  }
}

function renderKittyActions(bar) {
  const need = S.kittySize - selected.size;
  bar.appendChild(hintEl(`你拿到 ${S.kittySize} 张底牌,选 ${S.kittySize} 张扣回（避免扣分数牌）`));
  const b = mkBtn(need > 0 ? `扣底（还需 ${need} 张）` : (need < 0 ? `多选了 ${-need} 张` : '确认扣底'), () => {
    send({ type: 'bury', ids: [...selected] });
  });
  b.disabled = need !== 0;
  bar.appendChild(b);
}

function renderPlayActions(bar) {
  const cards = selectedCards();
  const isLead = !S.trickPlays || S.trickPlays.length === 0;
  const lead = isLead ? null : detectCombo(S.trickPlays[0].cards, S.trumpSuit);
  let valid = false, info = '';
  if (cards.length) {
    if (isLead) {
      const c = detectCombo(cards, S.trumpSuit);
      valid = !!c;
      info = c ? comboName(c) : '首攻必须是 单张/对子/拖拉机';
    } else {
      valid = isLegalFollow(S.hand, lead, cards, S.trumpSuit);
      info = valid ? `跟牌 ${cards.length} 张` : '不符合跟牌规则';
    }
  } else {
    info = isLead ? '请选牌首攻（单/对/拖拉机）' : `请跟 ${lead.length} 张（${comboName(lead)}）`;
  }
  bar.appendChild(hintEl(info));
  const play = mkBtn('出牌', () => send({ type: 'play', ids: [...selected] }));
  play.disabled = !valid;
  bar.appendChild(play);
  if (cards.length) bar.appendChild(mkBtn('清空', () => { selected.clear(); renderHand(); renderActions(); }, 'ghost'));
}

// ---------- 弹窗:入口 / 大厅 / 结算 ----------
function showOverlay(html) { $('dialog').innerHTML = html; $('overlay').classList.remove('hidden'); }
function hideOverlay() { $('overlay').classList.add('hidden'); }

function showEntry() {
  showOverlay(`<h2>飙分 · 联机</h2>
    <p class="sub">房间码开房 · 人不够电脑补位 · 掉线自动托管</p>
    <input id="nickin" class="txt" placeholder="你的昵称" maxlength="12" value="${localStorage.getItem(LS_NICK) || ''}">
    <div class="row">
      <button class="btn big" id="c3">创建 3 人房</button>
      <button class="btn big" id="c4">创建 4 人房</button>
    </div>
    <div class="row joinrow">
      <input id="codein" class="txt code" placeholder="房间码" maxlength="4" autocapitalize="characters">
      <button class="btn" id="jn">加入房间</button>
    </div>
    <p class="sub tip">想打单机?<a href="index.html">单机版入口</a></p>`);
  const takeNick = () => {
    const v = $('nickin').value.trim().slice(0, 12) || '玩家';
    localStorage.setItem(LS_NICK, v);
    return v;
  };
  const create = players => {
    me = { name: takeNick() };
    openThen(() => send({ type: 'create', players, name: me.name }));
  };
  $('c3').onclick = () => create(3);
  $('c4').onclick = () => create(4);
  $('jn').onclick = () => {
    const code = $('codein').value.trim().toUpperCase();
    if (code.length !== 4) return toast('房间码是 4 位', true);
    me = { name: takeNick(), room: code };
    openThen(() => send({ type: 'join', room: code, name: me.name, token: '' }));
  };
  $('codein').onkeydown = e => { if (e.key === 'Enter') $('jn').click(); };
}

function openThen(fn) {
  if (wsReady) return fn();
  connect(fn);
}

function renderLobbyOverlay() {
  renderStatus();
  const rows = S.seats.map((s, i) => {
    const stat = !s.taken ? '<span class="dot empty"></span>空位(开局由电脑补)'
      : `<span class="dot ${s.connected ? 'on' : 'off'}"></span>${i === S.mySeat ? '你 · ' : ''}${s.name}${s.bot ? ' 🤖' : ''}${i === S.hostSeat ? ' <b class="host">房主</b>' : ''}`;
    return `<div class="seatrow ${i === S.mySeat ? 'me' : ''}">${i + 1}号位　${stat}</div>`;
  }).join('');
  const humanCount = S.seats.filter(s => s.taken && !s.bot).length;
  const iAmHost = S.hostSeat === S.mySeat;
  showOverlay(`<h2>房间已建好</h2>
    <p class="sub">把房间码发给朋友,同一 WiFi 打开本页输入即可加入</p>
    <div class="codebox" id="codebox" title="点击复制">${S.room}</div>
    <div class="seatlist">${rows}</div>
    <div class="row">
      ${iAmHost
      ? `<button class="btn big" id="startbtn">开始游戏${humanCount < S.players ? '（空位电脑补）' : ''}</button>`
      : `<p class="sub">等待房主开始…（已进 ${humanCount}/${S.players} 人）</p>`}
    </div>`);
  $('codebox').onclick = async () => {
    try { await navigator.clipboard.writeText(S.room); toast('房间码已复制'); }
    catch { toast(`房间码:${S.room}`); }
  };
  if (iAmHost) $('startbtn').onclick = () => send({ type: 'start' });
}

function showResult() {
  const r = S.result;
  if (!r) return;
  const rows = r.scores.map((sc, i) =>
    `<div class="result-line"><span>${seatName(i)} ${i === r.declarer ? '(庄)' : ''}　本局 ${r.deltas[i] >= 0 ? '+' : ''}${r.deltas[i]}</span><span>累计 ${sc}</span></div>`
  ).join('');
  const kittyPts = (S.buried || []).reduce((a, c) => a + pointValue(c), 0);
  showOverlay(`<h2>${r.label}</h2>
    <p>庄家 ${seatName(r.declarer)} 喊 ${r.contract}　闲家线 ${r.line}</p>
    <p>闲家共捡 <b>${r.xianPoints}</b> 分${r.lastTrickBonus ? `（含底牌 ${r.lastTrickBonus}）` : ''}　·　底分 ${r.stake}</p>
    <p>底牌翻开（${kittyPts} 分${r.lastTrickBonus ? '，已被闲家捡走' : '，归庄家'}）：</p>
    <div id="kittyreveal" class="cap-cards"></div>
    ${rows}
    <div class="row"><button class="btn" id="nextbtn">下一局</button></div>`);
  const kr = $('kittyreveal');
  for (const c of (S.buried || []).slice().sort((a, b) => pointValue(b) - pointValue(a) || b.rank - a.rank))
    kr.appendChild(cardEl(c, { small: true }));
  $('nextbtn').onclick = () => send({ type: 'next' });
}

// ---------- 入口 ----------
$('leave').onclick = () => {
  if (S && S.started && S.phase !== 'done' && !confirm('对局进行中,确定退出?退出后 AI 托管,可凭本机重新进入。')) return;
  intentionalClose = true;
  localStorage.removeItem(LS_SESSION);
  if (ws) ws.close();
  me = { name: me.name };
  S = null;
  location.reload();
};

// 有会话 → 自动重连回房;否则入口页
if (me && me.room && me.token) {
  connect(() => sendJoin());
  showOverlay('<h2>飙分 · 联机</h2><p class="sub">正在回到房间 ' + me.room + ' …</p>');
  // 3 秒还没进去就给出手动入口
  setTimeout(() => { if (!S) showEntry(); }, 3000);
} else {
  showEntry();
}
