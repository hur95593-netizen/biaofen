// src/combos.js — 牌型识别、压牌比较、收墩判定
import { cardGroup, strength } from './cards.js';

// 识别牌型。返回 { type:'single'|'pair'|'tractor', length, group, top, pairs? } 或 null(非法/混合组)
export function detectCombo(cards, trumpSuit) {
  if (!cards || cards.length === 0) return null;
  const group = cardGroup(cards[0], trumpSuit);
  if (!cards.every(c => cardGroup(c, trumpSuit) === group)) return null; // 单一牌型必须同组

  if (cards.length === 1)
    return { type: 'single', length: 1, group, top: strength(cards[0], trumpSuit) };

  // 配对:同花色同点数,且每种恰好 2 张
  const byKey = new Map();
  for (const c of cards) {
    const k = c.suit + '-' + c.rank;
    if (!byKey.has(k)) byKey.set(k, { card: c, count: 0 });
    byKey.get(k).count++;
  }
  if (![...byKey.values()].every(v => v.count === 2)) return null;

  if (cards.length === 2)
    return { type: 'pair', length: 2, group, top: strength(cards[0], trumpSuit) };

  // 拖拉机:各对子 strength 必须连续(相邻差 1)。
  // 不同花色的副主(如 ♥3♦3)strength 相同 → 差 0 → 判否;王与3 间有空挡 → 王孤岛。
  const ps = [...byKey.values()].map(v => strength(v.card, trumpSuit)).sort((a, b) => a - b);
  for (let i = 1; i < ps.length; i++)
    if (ps[i] - ps[i - 1] !== 1) return null;
  return { type: 'tractor', length: cards.length, group, pairs: ps.length, top: ps[ps.length - 1] };
}

// b 能否压过 a(a 为当前最大,b 为新出)。两者需同型同长。
export function beats(b, a) {
  if (!b || !a) return false;
  if (b.type !== a.type || b.length !== a.length) return false;
  if (a.group === 'TRUMP') return b.group === 'TRUMP' && b.top > a.top;
  if (b.group === 'TRUMP') return true;            // 用主牌杀边牌
  if (b.group === a.group) return b.top > a.top;    // 同花色比大小
  return false;                                     // 不同边花色:垫牌,压不过
}

// 一墩收谁。plays: [{ cards }],第 0 个为首攻。返回获胜下标。
export function resolveTrick(plays, trumpSuit) {
  let winner = 0;
  let best = detectCombo(plays[0].cards, trumpSuit);
  for (let i = 1; i < plays.length; i++) {
    const c = detectCombo(plays[i].cards, trumpSuit);
    if (beats(c, best)) { winner = i; best = c; }
  }
  return winner;
}
