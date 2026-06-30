// src/ai.js — 电脑玩家(记牌 + 抢分/封锁 + 喂分/躲分)
import { strength, cardGroup, isTrump, tractorRank } from './cards.js';
import { beats, detectCombo } from './combos.js';
import { maxTractorLen, isLegalFollow } from './follow.js';
import { pointValue } from './game.js';

const ascS = (cards, t) => cards.slice().sort((a, b) => strength(a, t) - strength(b, t));
const descS = (cards, t) => cards.slice().sort((a, b) => strength(b, t) - strength(a, t));
const sideOf = (hand, t) => hand.filter(c => cardGroup(c, t) !== 'TRUMP');
const trumpOf = (hand, t) => hand.filter(c => cardGroup(c, t) === 'TRUMP');

function groupByKey(cardsG) {
  const m = new Map();
  for (const c of cardsG) { const k = c.suit + '-' + c.rank; if (!m.has(k)) m.set(k, []); m.get(k).push(c); }
  return m;
}
const pairList = cardsG => [...groupByKey(cardsG).values()].filter(a => a.length >= 2).map(a => a.slice(0, 2));
const singleList = cardsG => [...groupByKey(cardsG).values()].filter(a => a.length === 1).map(a => a[0]);

// 在对子列表里找一条长度 k、且最大那对 strength > minTop 的拖拉机(按自然阶梯 tractorRank,同 lane)。
// 取满足条件里"最小"(top 最低)的一条;找不到返回 null。与 combos/follow 的相邻判定一致。
function findLadderRun(pairs, k, t, minTop = -Infinity) {
  const byLane = new Map();
  for (const p of pairs) {
    const r = tractorRank(p[0], t);
    if (!byLane.has(r.lane)) byLane.set(r.lane, []);
    byLane.get(r.lane).push({ p, pos: r.pos, alt: r.alt, s: strength(p[0], t) });
  }
  let found = null;
  for (const list of byLane.values()) {
    // 主 A 有两个可选阶梯位(同 lane 最多一对 A)→ 分别试 pos 与 alt
    const flex = list.find(x => x.alt !== undefined);
    const fixed = list.filter(x => x.alt === undefined);
    const variants = flex
      ? [[...fixed, { ...flex }], [...fixed, { ...flex, pos: flex.alt }]]
      : [fixed];
    for (const variant of variants) {
      const arr = variant.slice().sort((a, b) => a.pos - b.pos);
      for (let i = 0; i + k <= arr.length; i++) {
        let ok = true;
        for (let j = 1; j < k; j++) if (arr[i + j].pos - arr[i + j - 1].pos !== 1) { ok = false; break; }
        if (!ok) continue;
        const window = arr.slice(i, i + k);
        const top = Math.max(...window.map(x => x.s));
        if (top <= minTop) continue;
        if (!found || top < found.top) found = { run: window.map(x => x.p), top };
      }
    }
  }
  return found ? found.run : null;
}

// 已经亮出的所有牌(用于记牌)
function seenCards(g) {
  const out = [];
  for (const tr of g.tricks) for (const p of tr.plays) out.push(...p.cards);
  for (const p of g.trickPlays) out.push(...p.cards);
  return out;
}
// 同(边)花色里比 card 更大、且还没出现(未亮出、不在我手)的张数 —— 0 即为该花色当前最大(boss)
function unseenHigher(card, seen, hand, t) {
  if (cardGroup(card, t) === 'TRUMP') return 99;
  const suit = card.suit, s = strength(card, t);
  let cnt = 0;
  for (let rank = 4; rank <= 14; rank++) {
    if (rank === 2 || rank === 3) continue;
    if (strength({ suit, rank }, t) <= s) continue;
    let copies = 2;
    copies -= seen.filter(c => c.suit === suit && c.rank === rank).length;
    copies -= hand.filter(c => c.suit === suit && c.rank === rank).length;
    if (copies > 0) cnt += copies;
  }
  return cnt;
}

// ---- 喊分(逐级 +10,直到超出自己的目标)----
function bidTarget(hand) {
  let jok = 0, threes = 0, twos = 0; const sc = { S: 0, H: 0, D: 0, C: 0 };
  for (const c of hand) {
    if (c.suit === 'JOKER') jok++;
    else { if (c.rank === 3) threes++; else if (c.rank === 2) twos++; sc[c.suit]++; }
  }
  const best = Math.max(sc.S, sc.H, sc.D, sc.C);
  const str = jok * 1.5 + threes * 1.2 + twos * 1.0 + best * 0.4;
  // 烂牌返回 <100(弃喊),只有够强的手牌才往上喊;上限 200
  return Math.min(200, 100 + 10 * Math.round(str - 13));
}
export function aiBid(g, seat) {
  const lv = g.nextBidLevel();
  return bidTarget(g.hands[seat]) >= lv ? lv : null;   // 愿意就加最小一档,否则放弃
}

// ---- 亮主:选最长花色当主 ----
export function aiTrump(g, seat) {
  const sc = { S: 0, H: 0, D: 0, C: 0 };
  for (const c of g.hands[seat]) if (c.suit !== 'JOKER') sc[c.suit]++;
  return ['S', 'H', 'D', 'C'].reduce((b, s) => sc[s] > sc[b] ? s : b, 'S');
}

// ---- 扣底:扣最没用的(非主、非分、低点)----
function discardScore(c, t) {
  let s = 0;
  if (isTrump(c, t)) s += 1000;
  if (pointValue(c)) s += 500;
  s += cardGroup(c, t) === 'TRUMP' ? 0 : c.rank;
  return s;
}
export function aiBury(g, seat) {
  const t = g.trumpSuit, hand = g.hands[seat], need = g.kittySize, discards = [];
  // 1) 优先把"短的、无分的边花色"整门扣掉做空门 → 以后那门一出就能用主牌杀
  const bySuit = { S: [], H: [], D: [], C: [] };
  for (const c of hand) if (cardGroup(c, t) !== 'TRUMP') bySuit[c.suit].push(c);
  const suits = ['S', 'H', 'D', 'C'].filter(s => bySuit[s].length)
    .sort((a, b) => bySuit[a].length - bySuit[b].length);
  for (const s of suits) {
    const grp = bySuit[s];
    if (grp.length <= need - discards.length && !grp.some(pointValue)) discards.push(...grp);
  }
  // 2) 剩余名额:扣最没用的(非主、非分、低点)
  if (discards.length < need) {
    const ids = new Set(discards.map(c => c.id));
    for (const c of hand.filter(c => !ids.has(c.id)).sort((a, b) => discardScore(a, t) - discardScore(b, t))) {
      if (discards.length >= need) break;
      discards.push(c);
    }
  }
  return discards.slice(0, need);
}

// ---- 首攻 ----
export function aiLead(g, seat) {
  const t = g.trumpSuit, hand = g.hands[seat], isZhuang = seat === g.declarer;
  const side = sideOf(hand, t), trumps = trumpOf(hand, t);
  if (isZhuang && trumps.length >= 5) return [descS(trumps, t)[0]];      // 庄家拉主(主多时连甩大主)
  const bosses = side.filter(c => unseenHigher(c, seenCards(g), hand, t) === 0); // 当前最大的边牌
  if (bosses.length) return [descS(bosses, t)[0]];                       // 兑现 boss:稳赢一墩
  return [(side.length ? ascS(side, t) : ascS(hand, t))[0]];            // 无 boss → 出小牌,别白送大牌
}

// ---- 跟牌:构造一手合法“垫牌”(默认丢最小)----
export function buildFollow(hand, lead, t) {
  const N = lead.length, G = lead.group;
  const handG = hand.filter(c => cardGroup(c, t) === G);
  const other = hand.filter(c => cardGroup(c, t) !== G);
  const m = handG.length;
  if (m <= N) return handG.concat(ascS(other, t).slice(0, N - m));
  if (lead.type === 'single') return [ascS(handG, t)[0]];
  if (lead.type === 'pair') {
    const pairs = pairList(handG);
    if (pairs.length) return pairs.sort((a, b) => strength(a[0], t) - strength(b[0], t))[0];
    const singles = singleList(handG);
    return G === 'TRUMP' ? descS(singles, t).slice(0, 2) : ascS(singles, t).slice(0, 2);
  }
  const k = N / 2, pairs = pairList(handG);
  const required = Math.min(k, pairs.length);
  const lowPairs = () => pairs.slice().sort((a, b) => strength(a[0], t) - strength(b[0], t)).slice(0, required);
  const chosen = (maxTractorLen(handG, t) >= k && findLadderRun(pairs, k, t)) || lowPairs();
  let cards = [].concat(...chosen);
  const need = N - cards.length;
  if (need > 0) {
    const singles = singleList(handG);
    cards = cards.concat(G === 'TRUMP' ? descS(singles, t).slice(0, need) : ascS(singles, t).slice(0, need));
  }
  return cards;
}

// 丢牌排序键:feed=喂分(先丢大分牌,其余丢小)；否则躲分(先丢小杂牌,分牌最后)
function dumpKey(c, t, feed) {
  const pv = pointValue(c);
  return feed ? (pv ? -1000 - pv * 10 : strength(c, t)) : (pv ? 10000 + pv : strength(c, t));
}
const dumpOrder = (cards, t, feed) => cards.slice().sort((a, b) => dumpKey(a, t, feed) - dumpKey(b, t, feed));

// 不抢时的智能垫牌:队友赢就喂分,对手赢就躲分
function chooseDump(hand, lead, t, feed) {
  const N = lead.length, G = lead.group;
  const handG = hand.filter(c => cardGroup(c, t) === G);
  const other = hand.filter(c => cardGroup(c, t) !== G);
  const m = handG.length;
  if (m <= N) return handG.concat(dumpOrder(other, t, feed).slice(0, N - m));
  if (lead.type === 'single') return [dumpOrder(handG, t, feed)[0]];
  if (lead.type === 'pair') {
    const pairs = pairList(handG);
    if (pairs.length) return pairs.sort((a, b) => dumpKey(a[0], t, feed) - dumpKey(b[0], t, feed))[0];
    const singles = singleList(handG);
    return G === 'TRUMP' ? descS(singles, t).slice(0, 2) : dumpOrder(singles, t, feed).slice(0, 2);
  }
  return buildFollow(hand, lead, t); // 拖拉机较少见,退回最小垫
}

// 在 cardsG 里找压过 minTop 的、同型同长的最小组合;没有返回 null
function findBeatingInGroup(cardsG, lead, minTop, t) {
  if (lead.type === 'single') {
    const c = ascS(cardsG.filter(x => strength(x, t) > minTop), t)[0];
    return c ? [c] : null;
  }
  if (lead.type === 'pair') {
    const p = pairList(cardsG).filter(p => strength(p[0], t) > minTop)
      .sort((a, b) => strength(a[0], t) - strength(b[0], t))[0];
    return p || null;
  }
  const k = lead.length / 2;
  const run = findLadderRun(pairList(cardsG), k, t, minTop);
  return run ? run.flat() : null;
}
export function buildWinningFollow(hand, lead, best, t) {
  const G = lead.group;
  const handG = hand.filter(c => cardGroup(c, t) === G);
  const trumps = trumpOf(hand, t);
  if (handG.length > 0) {
    if (best.group !== G) return null;
    if (handG.length < lead.length) return null;
    return findBeatingInGroup(handG, lead, best.top, t);
  }
  if (G !== 'TRUMP') {
    if (trumps.length < lead.length) return null;
    return findBeatingInGroup(trumps, lead, best.group === 'TRUMP' ? best.top : -1, t);
  }
  return null;
}

// ---- 跟牌决策 ----
export function aiFollow(g, seat) {
  const t = g.trumpSuit, lead = g.leadCombo, hand = g.hands[seat];
  const isZhuang = seat === g.declarer;

  let best = g.trickPlays[0].combo, bi = 0;
  for (let i = 1; i < g.trickPlays.length; i++)
    if (beats(g.trickPlays[i].combo, best)) { best = g.trickPlays[i].combo; bi = i; }
  const winnerIsZhuang = g.trickPlays[bi].seat === g.declarer;
  const points = g.trickPlays.reduce((s, p) => s + p.cards.reduce((a, c) => a + pointValue(c), 0), 0);
  const isLast = g.trickPlays.length === g.players - 1;

  const win = buildWinningFollow(hand, lead, best, t);
  let wantWin = false;
  if (win) {
    if (isZhuang) wantWin = !winnerIsZhuang && (points > 0 || isLast);   // 庄家:封锁闲家的分墩
    else wantWin = winnerIsZhuang && (points > 0 || isLast);             // 闲家:只抢庄家的墩,不抢队友
  }
  if (wantWin && isLegalFollow(hand, lead, win, t)) return win;

  // 不抢 → 智能垫牌:队友(闲家)赢、且庄家已出牌(吃不动了)才喂分;否则躲分(不送分给庄家)
  const zhuangPlayed = g.trickPlays.some(p => p.seat === g.declarer);
  const feed = !isZhuang && !winnerIsZhuang && zhuangPlayed;
  const play = chooseDump(hand, lead, t, feed);
  return isLegalFollow(hand, lead, play, t) ? play : buildFollow(hand, lead, t);
}
