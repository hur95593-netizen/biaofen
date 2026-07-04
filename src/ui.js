// src/ui.js — 界面与交互控制器(人类=0号位,其余电脑)
import { SUIT_SYMBOL, RANK_LABEL, isJoker, isTrump, sortHand, BIG_JOKER, SUITS } from './cards.js';
import { detectCombo } from './combos.js';
import { Game, pointValue } from './game.js';
import { SFX } from './sfx.js';
import * as AI from './ai.js';

const HUMAN = 0;
const AI_DELAY = 750, TRICK_PAUSE = 1400;
const SUIT_NAME = { S: '黑桃 ♠', H: '红桃 ♥', D: '方块 ♦', C: '梅花 ♣' };

const $ = id => document.getElementById(id);
let g = null;
let selected = new Set();
let frozenTrick = null;     // 收墩后定格展示
let aiTimer = null;

const seatName = s => (s === HUMAN ? '你' : '电脑' + s);

// ---------- 牌面 ----------
function cardEl(card, { small = false, faceDown = false } = {}) {
  const d = document.createElement('div');
  if (faceDown) { d.className = 'card back' + (small ? ' small' : ''); return d; }
  const joker = isJoker(card);
  const red = joker ? card.rank === BIG_JOKER : (card.suit === 'H' || card.suit === 'D');
  d.className = 'card ' + (red ? 'red' : 'black') + (small ? ' small' : '') + (joker ? ' joker' : '');
  d.dataset.id = card.id;
  const r = joker ? (card.rank === BIG_JOKER ? '大' : '小') : RANK_LABEL[card.rank];
  const s = joker ? '王' : SUIT_SYMBOL[card.suit];
  d.innerHTML = `<span class="idx"><span class="r">${r}</span><span class="s">${s}</span></span><span class="big">${s}</span>`;
  return d;
}
function pile(cards, opts) {
  const w = document.createElement('div'); w.className = 'cardpile';
  cards.forEach(c => w.appendChild(cardEl(c, opts)));
  return w;
}

// ---------- 渲染 ----------
function render() {
  if (!g) return;
  renderStatus();
  renderOpponents();
  renderTrick();
  renderCaptured();
  renderHand();
  renderActions();
}

function roleTag(seat) {
  if (g.declarer == null) return '';
  return seat === g.declarer ? '庄' : '闲';
}

function renderStatus() {
  const parts = [`第 ${g.handNo} 局`];
  if (g.trumpSuit) parts.push(`主：${SUIT_NAME[g.trumpSuit]}`);
  if (g.contract) parts.push(`喊分 ${g.contract}（闲家线 ${200 - g.contract}）`);
  if (g.declarer != null) parts.push(`庄家：${seatName(g.declarer)}`);
  if (g.phase === 'play') parts.push(`闲家已捡 ${g.xianPoints} 分`);
  $('status').textContent = parts.join('　·　');
}

function renderOpponents() {
  const box = $('opponents'); box.innerHTML = '';
  for (let s = 1; s < g.players; s++) {
    const o = document.createElement('div');
    o.className = 'opp' + (turnSeat() === s ? ' turn' : '');
    const isZ = g.declarer === s;
    o.innerHTML =
      `<div class="name">${seatName(s)}<span class="role ${isZ ? 'zhuang' : ''}">${isZ ? '庄' : '闲'}</span></div>
       <div class="count">手牌 ${g.hands[s].length} 张　积分 ${g.scores[s]}</div>`;
    box.appendChild(o);
  }
}

function turnSeat() {
  if (g.phase === 'bidding') return g.bidTurn;
  if (g.phase === 'play') return g.turn;
  if (g.phase === 'declare' || g.phase === 'kitty') return g.declarer;
  return -1;
}

function renderTrick() {
  const t = $('trick'); t.innerHTML = '';
  const show = frozenTrick ? frozenTrick.plays : g.trickPlays;
  const winnerSeat = frozenTrick ? frozenTrick.winnerSeat : -1;
  if (!show || !show.length) {
    if (g.phase === 'play') t.innerHTML = `<div class="trickplay"><div class="who turnwho">${seatName(turnSeat())}<i>${roleTag(turnSeat())}</i> 出牌…</div></div>`;
    return;
  }
  for (const p of show) {
    const isZ = p.seat === g.declarer;
    const col = document.createElement('div');
    col.className = 'trickplay' + (p.seat === winnerSeat ? ' win' : '') + (isZ ? ' zhuangplay' : '');
    const who = document.createElement('div'); who.className = 'who';
    who.innerHTML = `${seatName(p.seat)}<i class="${isZ ? 'z' : 'x'}">${roleTag(p.seat)}</i>` + (p.seat === winnerSeat ? ' ✓收墩' : '');
    const cards = pile(p.cards, { small: true }); cards.className = 'cards';
    col.appendChild(who); col.appendChild(cards); t.appendChild(col);
  }
}

function renderCaptured() {
  const box = $('captured');
  const caps = g.xianCaptured || [];
  const active = (g.phase === 'play' || g.phase === 'done') && caps.length;
  box.className = active ? '' : 'empty';
  box.innerHTML = '';
  if (!active) return;
  const label = document.createElement('span');
  label.className = 'cap-label';
  label.textContent = `闲家捡分 ${g.xianPoints}`;
  const strip = pile(caps.slice().sort((a, b) => pointValue(b) - pointValue(a) || b.rank - a.rank), { small: true });
  strip.className = 'cap-cards';
  box.appendChild(label); box.appendChild(strip);
}

function renderHand() {
  const meta = $('me-meta');
  const isZ = g.declarer === HUMAN;
  meta.innerHTML = `<span class="role ${isZ ? 'zhuang' : ''}">${g.declarer == null ? '—' : (isZ ? '庄家' : '闲家')}</span>
    <b>${seatName(HUMAN)}</b>　积分 ${g.scores[HUMAN]}　手牌 ${g.hands[HUMAN].length} 张`;

  const h = $('hand'); h.innerHTML = '';
  const sorted = sortHand(g.hands[HUMAN], g.trumpSuit || '_');
  const myTurn = (g.phase === 'play' && g.turn === HUMAN) || (g.phase === 'kitty' && g.declarer === HUMAN);
  for (const c of sorted) {
    const e = cardEl(c);
    if (g.trumpSuit && isTrump(c, g.trumpSuit)) e.classList.add('trump');
    if (selected.has(c.id)) e.classList.add('sel');
    if (myTurn) e.onclick = () => toggleCard(c.id);
    else e.classList.add('dim');
    h.appendChild(e);
  }
}

function toggleCard(id) {
  if (selected.has(id)) selected.delete(id); else selected.add(id);
  SFX.select();
  renderHand(); renderActions();
}
function selectedCards() { return g.hands[HUMAN].filter(c => selected.has(c.id)); }

function renderActions() {
  const bar = $('actionbar'); bar.innerHTML = '';
  if (!g) return;
  if (g.phase === 'bidding' && g.bidTurn === HUMAN) return renderBidActions(bar);
  if (g.phase === 'declare' && g.declarer === HUMAN) return renderDeclareActions(bar);
  if (g.phase === 'kitty' && g.declarer === HUMAN) return renderKittyActions(bar);
  if (g.phase === 'play' && g.turn === HUMAN) return renderPlayActions(bar);
  // 非我方行动
  const waiting = g.phase === 'done' ? '' : `等待 ${seatName(turnSeat())} …`;
  bar.innerHTML = `<div class="hint">${waiting}</div>`;
}

function renderBidActions(bar) {
  const hint = document.createElement('div'); hint.className = 'hint';
  hint.textContent = g.highBid ? `当前最高喊分 ${g.highBid}（${seatName(g.highBidder)}）` : '你先喊分（往上喊,100 起,10 的倍数;喊得最高者坐庄）';
  bar.appendChild(hint);
  const lv = g.nextBidLevel();
  for (const amt of [lv, lv + 10, lv + 20]) {
    if (amt > 200) break;
    const b = mkBtn(`喊 ${amt}`, () => { g.placeBid(HUMAN, amt); SFX.bid(); tick(); });
    bar.appendChild(b);
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
    sel.onchange = () => { g.placeBid(HUMAN, +sel.value); SFX.bid(); tick(); };
    bar.appendChild(sel);
  }
  bar.appendChild(mkBtn('不喊', () => { g.placeBid(HUMAN, null); tick(); }, 'ghost'));
}

function renderDeclareActions(bar) {
  bar.appendChild(hintEl('你坐庄,选一门花色当主（王/3/2 永远是主）'));
  for (const s of SUITS) {
    const b = mkBtn(SUIT_SYMBOL[s], () => {
      g.declareTrump(s);
      selected = new Set(g.kitty.map(c => c.id)); // 底牌默认选中,方便看清哪些是底牌
      tick();
    });
    b.className = 'btn suitbtn' + (s === 'H' || s === 'D' ? ' red' : '');
    bar.appendChild(b);
  }
}

function renderKittyActions(bar) {
  const need = g.kittySize - selected.size;
  bar.appendChild(hintEl(`你拿到 ${g.kittySize} 张底牌,选 ${g.kittySize} 张扣回（避免扣分数牌）`));
  const b = mkBtn(need > 0 ? `扣底（还需 ${need} 张）` : '确认扣底', () => {
    g.buryCards(selectedCards()); selected.clear(); tick();
  });
  b.disabled = need !== 0;
  bar.appendChild(b);
}

function renderPlayActions(bar) {
  const cards = selectedCards();
  const isLead = g.isLeadTurn();
  let label = '出牌', valid = false, info = '';
  if (cards.length) {
    valid = g.validatePlay(HUMAN, cards);
    if (isLead) {
      const c = detectCombo(cards, g.trumpSuit);
      info = c ? comboName(c) : '首攻必须是 单张/对子/拖拉机';
    } else {
      info = valid ? `跟牌 ${cards.length} 张` : '不符合跟牌规则';
    }
  } else {
    info = isLead ? '请选牌首攻（单/对/拖拉机）' : `请跟 ${g.leadCombo.length} 张（${comboName(g.leadCombo)}）`;
  }
  bar.appendChild(hintEl(info));
  const play = mkBtn(label, () => doPlay(HUMAN, selectedCards()));
  play.disabled = !valid;
  bar.appendChild(play);
  if (cards.length) bar.appendChild(mkBtn('清空', () => { selected.clear(); render(); }, 'ghost'));
}

function comboName(c) {
  if (c.type === 'single') return '单张';
  if (c.type === 'pair') return '对子';
  return `拖拉机（${c.pairs} 连对）`;
}
function mkBtn(text, on, extra = '') {
  const b = document.createElement('button'); b.className = 'btn ' + extra; b.textContent = text; b.onclick = on; return b;
}
function hintEl(t) { const d = document.createElement('div'); d.className = 'hint'; d.textContent = t; return d; }
function flash(msg) { $('message').textContent = msg; }

// ---------- 流程驱动 ----------
function tick() {
  render();
  if (!g) return;
  const wait = (fn, ms = AI_DELAY) => { clearTimeout(aiTimer); aiTimer = setTimeout(fn, ms); };
  switch (g.phase) {
    case 'bidding':
      if (g.bidTurn !== HUMAN) wait(() => {
        const amt = AI.aiBid(g, g.bidTurn);
        g.placeBid(g.bidTurn, amt);
        if (amt) SFX.bid();
        tick();
      });
      break;
    case 'declare':
      if (g.declarer !== HUMAN) wait(() => { g.declareTrump(AI.aiTrump(g, g.declarer)); SFX.trump(); flash(`${seatName(g.declarer)} 亮主 ${SUIT_NAME[g.trumpSuit]}`); tick(); });
      break;
    case 'kitty':
      if (g.declarer !== HUMAN) wait(() => { g.buryCards(AI.aiBury(g, g.declarer)); tick(); });
      break;
    case 'play':
      if (g.turn !== HUMAN) wait(() => doPlay(g.turn, g.isLeadTurn() ? AI.aiLead(g, g.turn) : AI.aiFollow(g, g.turn)));
      break;
    case 'done':
      showResult();
      break;
  }
}

function doPlay(seat, cards) {
  const prev = g.tricks.length;
  try { g.playCards(seat, cards); }
  catch (e) { flash('出牌不合法'); return; }
  selected.clear();
  flash('');
  SFX.play();
  if (g.tricks.length > prev) {
    const tr = g.tricks[g.tricks.length - 1];
    frozenTrick = tr;
    const isXian = tr.winnerSeat !== g.declarer;
    SFX.trick();
    flash(`${seatName(tr.winnerSeat)} 收墩` + (isXian && tr.points ? `,闲家 +${tr.points} 分` : ''));
    render();
    clearTimeout(aiTimer);
    aiTimer = setTimeout(() => { frozenTrick = null; tick(); }, TRICK_PAUSE);
  } else {
    tick();
  }
}

// ---------- 弹窗 ----------
function showOverlay(html) { $('dialog').innerHTML = html; $('overlay').classList.remove('hidden'); }
function hideOverlay() { $('overlay').classList.add('hidden'); }

function showStart() {
  showOverlay(`<h2>飙分</h2>
    <p class="sub">常主:大小王、3、2(7 是普通牌) · 你坐下方,其余为电脑</p>
    <div class="row">
      <button class="btn big" id="p3">3 人</button>
      <button class="btn big" id="p4">4 人</button>
    </div>
    <p class="sub" style="margin-top:14px">和朋友联机?<a href="online.html" style="color:var(--gold)">联机版入口</a>(需启动联机服务器)</p>`);
  $('p3').onclick = () => startGame(3);
  $('p4').onclick = () => startGame(4);
}

function startGame(n) {
  clearTimeout(aiTimer);
  g = new Game({ players: n, humanSeat: HUMAN });
  g.startHand();
  selected.clear(); frozenTrick = null;
  hideOverlay(); flash(''); tick();
}

function showResult() {
  const r = g.result;
  if (r.deltas[HUMAN] > 0) SFX.win();
  else if (r.deltas[HUMAN] < 0) SFX.lose();
  const rows = g.scores.map((sc, i) =>
    `<div class="result-line"><span>${seatName(i)} ${i === r.declarer ? '(庄)' : ''}　本局 ${r.deltas[i] >= 0 ? '+' : ''}${r.deltas[i]}</span><span>累计 ${sc}</span></div>`
  ).join('');
  const kittyPts = g.buried.reduce((a, c) => a + pointValue(c), 0);
  showOverlay(`<h2>${r.label}</h2>
    <p>庄家 ${seatName(r.declarer)} 喊 ${r.contract}　闲家线 ${r.line}</p>
    <p>闲家共捡 <b>${r.xianPoints}</b> 分${r.lastTrickBonus ? `（含底牌 ${r.lastTrickBonus}）` : ''}　·　底分 ${r.stake}</p>
    <p>底牌翻开（${kittyPts} 分${r.lastTrickBonus ? '，已被闲家捡走' : '，归庄家'}）：</p>
    <div id="kittyreveal" class="cap-cards"></div>
    ${rows}
    <div class="row"><button class="btn" id="next">下一局</button></div>`);
  const kr = $('kittyreveal');
  for (const c of g.buried.slice().sort((a, b) => pointValue(b) - pointValue(a) || b.rank - a.rank))
    kr.appendChild(cardEl(c, { small: true }));
  $('next').onclick = () => { g.startHand(); selected.clear(); frozenTrick = null; hideOverlay(); flash(''); tick(); };
}

// 静音开关(记住偏好)
const sndBtn = document.createElement('button');
sndBtn.className = 'btn ghost';
sndBtn.textContent = SFX.muted ? '🔇' : '🔊';
sndBtn.onclick = () => { sndBtn.textContent = SFX.toggle() ? '🔇' : '🔊'; };
$('newgame').before(sndBtn);

$('newgame').onclick = showStart;
showStart();
