// src/follow.js — 跟牌合法性(跟牌结构 + 跟大)
// 规则见 飙分-规则.md 第 5 节:
//   首家出什么,按 拖拉机 → 对子 → 单牌 的优先级尽量凑同结构,且必须出满该组的牌;
//   跟大:被迫拆单张主牌凑数时,单张必须是最大的;副牌不跟大。
import { cardGroup, strength, tractorRank } from './cards.js';

function countByKey(cards) {
  const m = new Map();
  for (const c of cards) {
    const k = c.suit + '-' + c.rank;
    m.set(k, (m.get(k) || 0) + 1);
  }
  return m;
}
function reprByKey(cards) {
  const m = new Map();
  for (const c of cards) {
    const k = c.suit + '-' + c.rank;
    if (!m.has(k)) m.set(k, c);
  }
  return m;
}

// 对子数:每种(花色,点数)满 2 张算 1 对(两副牌每种最多 2 张)
export function pairCount(cards) {
  let p = 0;
  for (const n of countByKey(cards).values()) p += Math.floor(n / 2);
  return p;
}

// 落单牌的 strength,从大到小
function singletonStrengths(cards, trumpSuit) {
  const cnt = countByKey(cards), repr = reprByKey(cards), out = [];
  for (const [k, n] of cnt) if (n % 2 === 1) out.push(strength(repr.get(k), trumpSuit));
  return out.sort((a, b) => b - a);
}

// 一组阶梯位里的最长连续段长度
function longestRun(positions) {
  const s = [...new Set(positions)].sort((a, b) => a - b);
  let best = s.length ? 1 : 0, run = 1;
  for (let i = 1; i < s.length; i++) {
    run = (s[i] - s[i - 1] === 1) ? run + 1 : 1;
    if (run > best) best = run;
  }
  return best;
}

// 最长拖拉机(连续对子)长度。按「相邻刻度」分 lane(同花色/同孤岛)各算,主 A 两个取位都试。
export function maxTractorLen(cards, trumpSuit) {
  const cnt = countByKey(cards), repr = reprByKey(cards);
  const byLane = new Map(); // lane -> { fixed:[], altsForA:[pos,alt]|null }
  for (const [k, n] of cnt) {
    if (n < 2) continue;
    const r = tractorRank(repr.get(k), trumpSuit);
    if (!byLane.has(r.lane)) byLane.set(r.lane, { fixed: [], flexA: null });
    const L = byLane.get(r.lane);
    if (r.alt !== undefined) L.flexA = [r.pos, r.alt]; else L.fixed.push(r.pos);
  }
  let best = 0;
  for (const { fixed, flexA } of byLane.values()) {
    if (!flexA) best = Math.max(best, longestRun(fixed));
    else best = Math.max(best, longestRun([...fixed, flexA[0]]), longestRun([...fixed, flexA[1]]));
  }
  return best;
}

function isPair(cards) {
  return cards.length === 2 && cards[0].suit === cards[1].suit && cards[0].rank === cards[1].rank;
}

function isSubMultiset(sub, sup) {
  const have = new Map();
  for (const c of sup) have.set(c.id, (have.get(c.id) || 0) + 1);
  for (const c of sub) {
    const n = have.get(c.id) || 0;
    if (n <= 0) return false;
    have.set(c.id, n - 1);
  }
  return true;
}

function sameMultiset(a, b) {
  if (a.length !== b.length) return false;
  const x = a.slice().sort((p, q) => p - q), y = b.slice().sort((p, q) => p - q);
  return x.every((v, i) => v === y[i]);
}

// 跟大:play 的落单牌必须正好是 hand 落单牌里最大的 count 张
function topSingletonsOK(playG, handG, count, trumpSuit) {
  const want = singletonStrengths(handG, trumpSuit).slice(0, count);
  const got = singletonStrengths(playG, trumpSuit);
  return got.length === count && sameMultiset(want, got);
}

// play 是否为对 lead 的一手合法跟牌。lead 为 detectCombo 结果。
// 已知简化(待细化):当“自己最长拖拉机 < 首攻拖拉机长度”时,只强制“用满最大对子数”,
// 不强制把较短的拖拉机也连着出。常见的“有等长拖拉机必须跟”已强制。
export function isLegalFollow(hand, lead, play, trumpSuit) {
  const N = lead.length;
  if (!play || play.length !== N) return false;
  if (!isSubMultiset(play, hand)) return false;

  const G = lead.group;
  const inG = c => cardGroup(c, trumpSuit) === G;
  const handG = hand.filter(inG);
  const playG = play.filter(inG);
  const m = handG.length;
  const need = Math.min(N, m);
  if (playG.length !== need) return false;            // 必须出满该组的牌(有就得跟)

  if (m <= N) return true;                              // 该组牌被迫全出,无取舍

  // m > N:组内有取舍,按结构跟牌
  if (lead.type === 'single') return true;             // 任意一张

  if (lead.type === 'pair') {
    if (pairCount(handG) >= 1) return isPair(playG);    // 有对必须跟对(任意对)
    if (G === 'TRUMP') return topSingletonsOK(playG, handG, 2, trumpSuit); // 主牌跟大
    return true;                                        // 边牌:任意两张单
  }

  // tractor
  const k = N / 2;
  const required = Math.min(k, pairCount(handG));
  if (pairCount(playG) !== required) return false;      // 必须用满最大对子数
  if (maxTractorLen(handG, trumpSuit) >= k && maxTractorLen(playG, trumpSuit) < k)
    return false;                                       // 有(够长)拖拉机必须跟拖拉机
  const singlesNeeded = N - 2 * required;
  if (singlesNeeded > 0 && G === 'TRUMP')
    return topSingletonsOK(playG, handG, singlesNeeded, trumpSuit); // 单牌部分跟大
  return true;
}
