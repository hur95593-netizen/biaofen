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

// 组内大小(越大越强)。
// 主牌统一刻度:大王118 > 小王117 > [116空挡] > 3:115 > 2:114 > 主A 113 > 主K 112 …… 主4 103。
// 所有 3 同一档、所有 2 同一档(不分主副)。3 与 2 相邻 → ♥3♥3+♥2♥2 是拖拉机;
// 同花色才成对,不同花色的两对 3(同档)不连。116 空挡让“王”只和“王”连(王孤岛):3(115) 与 小王(117) 差 2。
export function strength(card, trumpSuit) {
  if (cardGroup(card, trumpSuit) !== 'TRUMP') return card.rank;   // 边牌:4..14
  if (card.rank === BIG_JOKER) return 118;
  if (card.rank === SMALL_JOKER) return 117;
  if (card.rank === 3) return 115;   // 所有 3 同级(常主)
  if (card.rank === 2) return 114;   // 所有 2 同级(常主)
  return card.rank + 99;             // 主花色 4..14(A) → 103..113
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
  return hand.slice().sort((a, b) => {
    const ga = cardGroup(a, trumpSuit), gb = cardGroup(b, trumpSuit);
    if (groupOrder[ga] !== groupOrder[gb]) return groupOrder[ga] - groupOrder[gb];
    return strength(b, trumpSuit) - strength(a, trumpSuit);
  });
}
