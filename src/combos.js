// src/combos.js — 牌型识别、压牌比较、收墩判定
import { cardGroup, strength, tractorRank } from './cards.js';

// 一组阶梯位是否连成一条拖拉机(排序后相邻差恰为 1,无重复)。
function isConsecutive(positions) {
  const s = positions.slice().sort((a, b) => a - b);
  for (let i = 1; i < s.length; i++)
    if (s[i] - s[i - 1] !== 1) return false;
  return true;
}

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

  const pairCards = [...byKey.values()].map(v => v.card);
  const top = Math.max(...pairCards.map(c => strength(c, trumpSuit))); // 比大小用最大那对

  if (cards.length === 2)
    return { type: 'pair', length: 2, group, top };

  // 拖拉机:各对子按「相邻刻度」连续,且同 lane(同花色/同孤岛 → 自动排除跨花色、王孤岛)。
  const ranks = pairCards.map(c => tractorRank(c, trumpSuit));
  const lane = ranks[0].lane;
  if (!ranks.every(r => r.lane === lane)) return null;
  // 主 A 有两个可选阶梯位(接 2 或接 K),同 lane 最多一对 A → 试每种取位能否连成。
  const fixed = ranks.filter(r => r.alt === undefined).map(r => r.pos);
  const flex = ranks.find(r => r.alt !== undefined);
  const linked = flex
    ? isConsecutive([...fixed, flex.pos]) || isConsecutive([...fixed, flex.alt])
    : isConsecutive(fixed);
  if (!linked) return null;
  return { type: 'tractor', length: cards.length, group, pairs: ranks.length, top };
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
