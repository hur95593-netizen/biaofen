// src/ai.js — 电脑玩家(记牌 + 抢分/封锁 + 喂分/躲分 + 断门防砸 + 跳喊)
import { strength, cardGroup, isTrump, tractorRank, BIG_JOKER, SMALL_JOKER, SUITS } from './cards.js';
import { beats, detectCombo } from './combos.js';
import { maxTractorLen, isLegalFollow, pairCount } from './follow.js';
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
// 一个组(边花色或主)的全部候选牌(每种 2 张)
function groupCandidates(group, t) {
  if (group !== 'TRUMP') {
    const out = [];
    for (let r = 4; r <= 14; r++) out.push({ suit: group, rank: r });
    return out;
  }
  const out = [{ suit: 'JOKER', rank: BIG_JOKER }, { suit: 'JOKER', rank: SMALL_JOKER }];
  for (const s of SUITS) out.push({ suit: s, rank: 3 }, { suit: s, rank: 2 });
  for (let r = 4; r <= 14; r++) out.push({ suit: t, rank: r });
  return out;
}

// cand 还没露面(不在已出牌、不在我手)的张数
function remainingCopies(cand, seen, hand) {
  let copies = 2;
  copies -= seen.filter(c => c.suit === cand.suit && c.rank === cand.rank).length;
  copies -= hand.filter(c => c.suit === cand.suit && c.rank === cand.rank).length;
  return Math.max(copies, 0);
}

// 组内(边花色与主牌通用)比 card 更大、还没露面的张数 —— 0 即当前最大(boss)
function unseenHigher(card, seen, hand, t) {
  const s = strength(card, t);
  let cnt = 0;
  for (const cand of groupCandidates(cardGroup(card, t), t))
    if (strength(cand, t) > s) cnt += remainingCopies(cand, seen, hand);
  return cnt;
}

// 组内比 card 更大、且对手还可能凑成一对的档位数 —— 0 即我的对子无对可压(不含主杀)
function unseenHigherPair(card, seen, hand, t) {
  const s = strength(card, t);
  let cnt = 0;
  for (const cand of groupCandidates(cardGroup(card, t), t))
    if (strength(cand, t) > s && remainingCopies(cand, seen, hand) === 2) cnt++;
  return cnt;
}

// 从打过的墩推断:谁在哪个组已经断门(没跟上首攻组)。返回 Map(seat → Set(group))
function voidGroups(g) {
  const out = new Map();
  const mark = (seat, group) => { if (!out.has(seat)) out.set(seat, new Set()); out.get(seat).add(group); };
  const scan = plays => {
    if (!plays.length || !plays[0].combo) return;
    const lead = plays[0].combo.group;
    for (const p of plays.slice(1))
      if (p.cards.some(c => cardGroup(c, g.trumpSuit) !== lead)) mark(p.seat, lead);
  };
  for (const tr of g.tricks) scan(tr.plays);
  scan(g.trickPlays);
  return out;
}

// 我在该边花色的赢牌会不会被对头用主砸掉:对头断了这门、且没断主、场上还有主
function ruffRisk(g, seat, group) {
  if (group === 'TRUMP') return false;
  if (othersTrumps(g, seat) <= 0) return false;
  const voids = voidGroups(g);
  for (let o = 0; o < g.players; o++) {
    if (o === seat) continue;
    if ((seat === g.declarer) === (o === g.declarer)) continue; // 只怕对头,不怕队友
    const v = voids.get(o);
    if (v && v.has(group) && !v.has('TRUMP')) return true;
  }
  return false;
}

// 对手手里(约)还剩多少主。底牌里的主看不见 → 宁可高估,多拉一轮
function othersTrumps(g, seat) {
  const t = g.trumpSuit;
  let total = 42; // 4王 + 8张3 + 8张2 + 主花色4..A共22张
  for (const c of seenCards(g)) if (isTrump(c, t)) total--;
  for (const c of g.hands[seat]) if (isTrump(c, t)) total--;
  return total;
}

// ---- 喊分 ----
// bidTarget 以"坐庄实力"评估手牌 → 我最多敢喊到多少
// 考量:王/常主(硬控制)、最长花色(主的长度)、对子(结构)、短门(可扣底做空门去杀)
function bidTarget(hand) {
  let jok = 0, threes = 0, twos = 0; const sc = { S: 0, H: 0, D: 0, C: 0 };
  for (const c of hand) {
    if (c.suit === 'JOKER') jok++;
    else { if (c.rank === 3) threes++; else if (c.rank === 2) twos++; sc[c.suit]++; }
  }
  const bestSuit = SUITS.reduce((b, s) => sc[s] > sc[b] ? s : b, 'S');
  const shorts = SUITS.filter(s => s !== bestSuit && sc[s] <= 1).length; // 空门潜力
  const str = jok * 1.6 + threes * 1.3 + twos * 1.0 +
    sc[bestSuit] * 0.5 + pairCount(hand) * 0.3 + shorts * 0.8;
  // 烂牌返回 <100(弃喊);实力越强目标越高,上限 200
  return Math.min(200, 100 + 10 * Math.round(str - 15));
}

// 返回喊分数;null = 不喊。实力大幅超过当前价 → 跳喊施压,吓退还想跟的人
export function aiBid(g, seat) {
  const lv = g.nextBidLevel();
  const target = bidTarget(g.hands[seat]);
  if (target < lv) return null;
  if (target >= lv + 30) return Math.min(lv + 20, 200); // 跳两档:抬高对方跟价成本
  return lv;
}

// ---- 亮主:选最长花色当主 ----
export function aiTrump(g, seat) {
  const sc = { S: 0, H: 0, D: 0, C: 0 };
  for (const c of g.hands[seat]) if (c.suit !== 'JOKER') sc[c.suit]++;
  return ['S', 'H', 'D', 'C'].reduce((b, s) => sc[s] > sc[b] ? s : b, 'S');
}

// ---- 扣底:扣最没用的;5/10 打不赢就藏进底牌护分,A/K 留着打 ----
function discardScore(c, t) {
  let s = 0;
  if (isTrump(c, t)) s += 1000;
  if (c.rank === 13) s += 800;       // K:分牌 + 大牌,尽量留着打
  else if (c.rank === 14) s += 500;  // A:boss,别扣
  else if (c.rank === 10) s -= 10;   // 10/5:藏进底牌护分(闲家抢不到)
  else if (c.rank === 5) s -= 40;
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
    // A/K 留着打;5/10 随短门扣掉反而是藏分
    if (grp.length <= need - discards.length && !grp.some(c => c.rank >= 13)) discards.push(...grp);
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

// ---- 首攻:拖拉机 > 庄家控主 > boss 对子 > boss 单张 > 小牌过渡 ----
// boss 兑现会避开"对头已断门、可能用主砸"的花色;拖拉机结构免疫(压它需要同长主拖拉机)不用避
export function aiLead(g, seat) {
  const t = g.trumpSuit, hand = g.hands[seat];
  const seen = seenCards(g);
  const risky = group => ruffRisk(g, seat, group);
  const throwCards = leadThrow(g, seat, seen);
  if (throwCards) return throwCards; // 甩牌:必大的主一把甩掉,省时又稳
  const run = leadTractor(hand, t, seen);
  if (run) return run; // 拖拉机几乎无解,还能一手甩掉多张
  if (seat === g.declarer) {
    const draw = leadDrawTrump(g, seat, seen);
    if (draw) return draw;
  }
  return leadBossPair(hand, t, seen, risky)
    || leadBossSingle(hand, t, seen, risky)
    || leadPartnerRuff(g, seat, seen) // 借刀杀人:甩分牌给队友的断门
    || smallLead(hand, t);
}

// 甩牌:手里"必大"(没有任何未见主牌能大过)的主 ≥3 张 → 一把甩掉
function leadThrow(g, seat, seen) {
  const t = g.trumpSuit, hand = g.hands[seat];
  const dominant = trumpOf(hand, t).filter(c => unseenHigher(c, seen, hand, t) === 0);
  if (dominant.length < 3) return null; // 一两张不值得甩,留着按牌型打
  return dominant;
}

// 值得首攻的拖拉机:3 对及以上直接出;2 对要求顶张已无更高对(boss)
function leadTractor(hand, t, seen) {
  const pairs = pairList(hand);
  if (pairs.length < 2) return null;
  for (let k = pairs.length; k >= 3; k--) {
    const run = findLadderRun(pairs, k, t);
    if (run) return run.flat();
  }
  let minTop = -Infinity;
  for (;;) {
    const run = findLadderRun(pairs, 2, t, minTop);
    if (!run) return null;
    const top = runTopCard(run, t);
    if (unseenHigherPair(top, seen, hand, t) === 0) return run.flat();
    minTop = strength(top, t); // 这条顶张不硬,往更高的找
  }
}

function runTopCard(run, t) {
  return run.reduce((top, p) => strength(p[0], t) > strength(top, t) ? p[0] : top, run[0][0]);
}

// 庄家控主(v4,经 3 人局 A/B 对战调优):
// boss 主对(必赢 + 跟大逼对手交最大单主)> boss 单张 > 便宜快拉(小对 > 小单);
// 对手全部断主即停。排序依据实测:必赢的先赢着拉,无必赢结构时快速消耗对手的主仍是净赚。
function leadDrawTrump(g, seat, seen) {
  const t = g.trumpSuit, hand = g.hands[seat];
  const trumps = trumpOf(hand, t);
  if (!trumps.length) return null;
  if (enemiesAllTrumpVoid(g, seat) || othersTrumps(g, seat) < 3) return null; // 对手主已尽,停手转攻
  const pairs = pairList(trumps);
  // 1) boss 主对:必赢 + 一墩拉走 6 张,跟大还能逼出对手的大王/主3
  let bossPair = null;
  for (const p of pairs) {
    if (unseenHigherPair(p[0], seen, hand, t) > 0) continue;
    if (!bossPair || strength(p[0], t) < strength(bossPair[0], t)) bossPair = p; // 最小的 boss 对就够赢
  }
  if (bossPair) return bossPair;
  // 2) boss 单张:必赢,拉走 3 张
  const top = descS(trumps, t)[0];
  if (unseenHigher(top, seen, hand, t) === 0) return [top];
  // 3) 无必赢结构但主够长:便宜快拉,优先小对
  if (trumps.length >= 6) {
    let lowPair = null;
    for (const p of pairs) {
      if (pointValue(p[0])) continue;
      if (!lowPair || strength(p[0], t) < strength(lowPair[0], t)) lowPair = p;
    }
    if (lowPair) return lowPair;
    const small = ascS(trumps, t).find(c => !pointValue(c));
    if (small) return [small];
  }
  return null;
}

// 所有对头都已亮出断主(跟主牌时垫过别的)→ 主拉干净了
function enemiesAllTrumpVoid(g, seat) {
  const voids = voidGroups(g);
  for (let o = 0; o < g.players; o++) {
    if (o === seat) continue;
    if ((seat === g.declarer) === (o === g.declarer)) continue;
    const v = voids.get(o);
    if (!v || !v.has('TRUMP')) return false;
  }
  return true;
}

// 借刀杀人(闲家、且庄家紧跟我后手时):队友断了某边门且还可能有主、庄家没断这门 →
// 故意甩一张分牌过去:庄被迫跟牌,队友最后用主杀,分数全归闲家。
function leadPartnerRuff(g, seat, seen) {
  if (seat === g.declarer) return null;
  if ((seat + 1) % g.players !== g.declarer) return null; // 需要 我 → 庄 → 队友 的顺序
  const t = g.trumpSuit, hand = g.hands[seat];
  const voids = voidGroups(g);
  let best = null, bestScore = 0;
  for (const c of hand) {
    const grp = cardGroup(c, t);
    if (grp === 'TRUMP' || !pointValue(c)) continue;
    let partnerCanRuff = false;
    for (let o = 0; o < g.players; o++) {
      if (o === seat || o === g.declarer) continue;
      const v = voids.get(o);
      if (v && v.has(grp) && !v.has('TRUMP')) partnerCanRuff = true;
    }
    if (!partnerCanRuff) continue;
    const dv = voids.get(g.declarer);
    if (dv && dv.has(grp)) continue; // 庄自己断门会反杀
    const score = pointValue(c) * 10 + c.rank;
    if (score > bestScore) { best = c; bestScore = score; }
  }
  return best ? [best] : null;
}

// 当前最大的一手是否为「队友打出的边花色必大牌」且庄家大概率只能跟着垫:
// 顶张组内当前最大 + 庄没亮过这门断门 + 庄曾跟过这门(证实有牌)→ 这墩基本归队友
function teammateBossSecured(g, bi, myHand) {
  const best = g.trickPlays[bi];
  if (!best.combo || best.combo.group === 'TRUMP') return false;
  const t = g.trumpSuit;
  let top = best.cards[0];
  for (const c of best.cards) if (strength(c, t) > strength(top, t)) top = c;
  if (unseenHigher(top, seenCards(g), myHand, t) > 0) return false;
  const voids = voidGroups(g);
  const dv = voids.get(g.declarer);
  if (dv && dv.has(best.combo.group)) return false; // 庄断门 → 可能用主杀
  return provenFollows(g, g.declarer, best.combo.group);
}

// seat 是否曾整手跟上过该组(证实他有这门牌)
function provenFollows(g, seat, group) {
  for (const tr of g.tricks) {
    if (!tr.plays.length || !tr.plays[0].combo || tr.plays[0].combo.group !== group) continue;
    for (const p of tr.plays) {
      if (p.seat !== seat) continue;
      if (p.cards.every(c => cardGroup(c, g.trumpSuit) === group)) return true;
    }
  }
  return false;
}

// 已无更高对的对子 → 兑现;优先带分的(闲家一手捡 20);避开会被主对砸的花色
function leadBossPair(hand, t, seen, risky) {
  let best = null, bestScore = -Infinity;
  for (const p of pairList(hand)) {
    const c = p[0];
    if (unseenHigherPair(c, seen, hand, t) > 0) continue;
    const grp = cardGroup(c, t);
    if (grp !== 'TRUMP' && risky(grp)) continue;
    const score = pointValue(c) * 20 + strength(c, t);
    if (score > bestScore) { best = p; bestScore = score; }
  }
  return best;
}

// 边花色里"当前最大"的落单牌 → 兑现,优先带分的;不拆对子;避开会被砸的花色
function leadBossSingle(hand, t, seen, risky) {
  let best = null, bestScore = -Infinity;
  for (const [, arr] of groupByKey(hand)) {
    if (arr.length !== 1) continue;
    const c = arr[0];
    if (cardGroup(c, t) === 'TRUMP') continue; // 主 boss 由庄家控主逻辑处理;闲家拉主反帮庄
    if (unseenHigher(c, seen, hand, t) > 0 || risky(c.suit)) continue;
    const score = pointValue(c) * 20 + strength(c, t);
    if (score > bestScore) { best = c; bestScore = score; }
  }
  return best ? [best] : null;
}

// 过渡:最小的不带分边单张 → 最小不带分边牌 → 最小边牌 → 最小不带分牌 → 最小牌
function smallLead(hand, t) {
  const side = sideOf(hand, t);
  if (side.length) {
    const singles = singleList(side).filter(c => !pointValue(c));
    if (singles.length) return [ascS(singles, t)[0]];
    const nonPoint = side.filter(c => !pointValue(c));
    if (nonPoint.length) return [ascS(nonPoint, t)[0]];
    return [ascS(side, t)[0]];
  }
  const pool = hand.filter(c => !pointValue(c));
  return [ascS(pool.length ? pool : hand, t)[0]];
}

// ---- 跟牌:构造一手合法“垫牌”(默认丢最小)----
export function buildFollow(hand, lead, t) {
  const N = lead.length, G = lead.group;
  const handG = hand.filter(c => cardGroup(c, t) === G);
  const other = hand.filter(c => cardGroup(c, t) !== G);
  const m = handG.length;
  if (m <= N) return handG.concat(ascS(other, t).slice(0, N - m));
  if (lead.type === 'single') return [ascS(handG, t)[0]];
  if (lead.type === 'throw') return ascS(handG, t).slice(0, N); // 甩牌:垫最小的 N 张
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
  if (lead.type === 'throw') return dumpOrder(handG, t, feed).slice(0, N); // 甩牌:按喂/躲原则垫满 N 张
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
  if (lead.type === 'throw') return null; // 甩牌是"必大"集合,压不了
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
    // 白捡节奏:对头正赢着,而我能用"反正当前最大"的同组单张吃 → 无分也抢(赢下一手首攻权)
    if (!wantWin && lead.type === 'single' && win.length === 1) {
      const enemyWinning = winnerIsZhuang !== isZhuang;
      if (enemyWinning && cardGroup(win[0], t) === lead.group &&
          unseenHigher(win[0], seenCards(g), hand, t) === 0) wantWin = true;
    }
  }
  if (wantWin && isLegalFollow(hand, lead, win, t)) return win;

  // 不抢 → 智能垫牌:队友(闲家)赢、且庄家已出牌(吃不动了)才喂分;否则躲分(不送分给庄家)
  const zhuangPlayed = g.trickPlays.some(p => p.seat === g.declarer);
  let feed = !isZhuang && !winnerIsZhuang && zhuangPlayed;
  // v4 闲家:队友领着「边花色必大牌」、庄被证实还有这门(跟过且没断)→ 不等庄出牌就喂分
  if (!feed && !isZhuang && !winnerIsZhuang && !zhuangPlayed) {
    feed = teammateBossSecured(g, bi, hand);
  }
  const play = chooseDump(hand, lead, t, feed);
  return isLegalFollow(hand, lead, play, t) ? play : buildFollow(hand, lead, t);
}
