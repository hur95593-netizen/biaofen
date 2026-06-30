// src/cards.js
// 「飙分」牌模型:108 张(两副),主花色分类与组内大小排序。
// 详细规则见 飙分-规则.md。

export const SUITS = ['S', 'H', 'D', 'C'];                 // ♠ ♥ ♦ ♣
export const SUIT_SYMBOL = { S: '♠', H: '♥', D: '♦', C: '♣', JOKER: '🃏' };

export const SMALL_JOKER = 16;
export const BIG_JOKER = 17;

export const RANK_LABEL = {
  2: '2', 3: '3', 4: '4', 5: '5', 6: '6', 7: '7', 8: '8', 9: '9', 10: '10',
  11: 'J', 12: 'Q', 13: 'K', 14: 'A', [SMALL_JOKER]: '小王', [BIG_JOKER]: '大王',
};

export function makeCard(suit, rank, copy = 0) {
  return { suit, rank, copy, id: `${suit}-${rank}-${copy}` };
}

export function isJoker(card) { return card.suit === 'JOKER'; }

export function cardLabel(card) {
  return isJoker(card) ? RANK_LABEL[card.rank] : SUIT_SYMBOL[card.suit] + RANK_LABEL[card.rank];
}

// 一副 54 张(52 + 大小王),两副共 108
export function buildDeck() {
  const cards = [];
  for (let copy = 0; copy < 2; copy++) {
    for (const suit of SUITS)
      for (let rank = 2; rank <= 14; rank++)
        cards.push(makeCard(suit, rank, copy));
    cards.push(makeCard('JOKER', SMALL_JOKER, copy));
    cards.push(makeCard('JOKER', BIG_JOKER, copy));
  }
  return cards;
}

// 常主:大小王、所有 3、所有 2;再加主花色全部 → 主牌
export function isTrump(card, trumpSuit) {
  if (isJoker(card)) return true;
  if (card.rank === 3 || card.rank === 2) return true;
  return card.suit === trumpSuit;
}

// 分组:'TRUMP' 或 边花色字母('H'/'D'/'C'/'S')
export function cardGroup(card, trumpSuit) {
  return isTrump(card, trumpSuit) ? 'TRUMP' : card.suit;
}

// 组内「比大小」刻度(越大越强)——决定谁压谁。与「拖拉机相邻」是两套规则(见 tractorRank)。
// 主牌:大王200 > 小王199 > 主3 198 > 副3 197 > 主2 196 > 副2 195 > 主A 194 > 主K 193 …… 主4 184。
// 即所有 3 > 所有 2;3 内主3>副3、2 内主2>副2(主花色那张更大)。边牌按点数 4..14。
export function strength(card, trumpSuit) {
  if (cardGroup(card, trumpSuit) !== 'TRUMP') return card.rank;   // 边牌:4..14
  if (card.rank === BIG_JOKER) return 200;
  if (card.rank === SMALL_JOKER) return 199;
  const mainSuit = card.suit === trumpSuit;
  if (card.rank === 3) return mainSuit ? 198 : 197;   // 主3 > 副3
  if (card.rank === 2) return mainSuit ? 196 : 195;   // 主2 > 副2(且所有3 > 所有2)
  return card.rank + 180;            // 主花色 4..14(A) → 184..194(均 < 副2 195)
}

// 「拖拉机相邻」刻度——只管连不连,与比大小分开。返回 { lane, pos, alt? }:
//   同 lane(同花色/同孤岛)且位置(pos)差 1 才相连。
//   主花色:ace-low 自然阶梯 A=1,2=2,3=3,…,K=13;主 A「两头都连」→ pos:1 兼 alt:14(接 2 也接 K)。
//   王:小王/大王 自成孤岛(lane 'JOKER',pos 16/17 相邻)。边牌:ace-high,pos = 点数 4..14。
export function tractorRank(card, trumpSuit) {
  if (isJoker(card)) return { lane: 'JOKER', pos: card.rank };          // 16、17 相邻
  if (isTrump(card, trumpSuit)) {
    if (card.rank === 14) return { lane: 'T-' + card.suit, pos: 1, alt: 14 }; // 主A:接2 或 接K(A 必为主花色)
    return { lane: 'T-' + card.suit, pos: card.rank };                 // 主3=3、主2=2、…、主K=13
  }
  return { lane: card.suit, pos: card.rank };                          // 边牌 ace-high 4..14
}

export function shuffle(cards, rng = Math.random) {
  const a = cards.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

// 发牌。players: 3 或 4。返回 { hands, kitty, kittySize, perHand }
// 4 人 → 每人 25、底牌 8;3 人 → 每人 33、底牌 9。
export function deal(cards, players) {
  const kittySize = players === 4 ? 8 : 9;
  const perHand = (cards.length - kittySize) / players;
  const hands = Array.from({ length: players }, () => []);
  let i = 0;
  for (let p = 0; p < players; p++)
    for (let k = 0; k < perHand; k++) hands[p].push(cards[i++]);
  return { hands, kitty: cards.slice(i), kittySize, perHand };
}

// 整理手牌(展示用):主牌在前,组内从大到小
export function sortHand(hand, trumpSuit) {
  const groupOrder = { TRUMP: 0, S: 1, H: 2, D: 3, C: 4 };
  const suitOrder = { S: 0, H: 1, D: 2, C: 3, JOKER: 4 };
  return hand.slice().sort((a, b) => {
    const ga = cardGroup(a, trumpSuit), gb = cardGroup(b, trumpSuit);
    if (groupOrder[ga] !== groupOrder[gb]) return groupOrder[ga] - groupOrder[gb];
    const sd = strength(b, trumpSuit) - strength(a, trumpSuit);
    if (sd !== 0) return sd;
    // 同强度(如不同花色的 3)→ 按花色、点数、copy 归拢,让相同的牌永远相邻(对子不被拆开)
    if (a.suit !== b.suit) return suitOrder[a.suit] - suitOrder[b.suit];
    if (a.rank !== b.rank) return b.rank - a.rank;
    return a.copy - b.copy;
  });
}
