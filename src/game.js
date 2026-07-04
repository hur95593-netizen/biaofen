// src/game.js — 「飙分」一桌/一局流程状态机
// 阶段 phase: bidding → declare → kitty → play → done
import { buildDeck, shuffle, deal, isTrump, strength } from './cards.js';
import { detectCombo, resolveTrick } from './combos.js';
import { isLegalFollow } from './follow.js';

// 分数牌:5=5,10=10,K=10
export function pointValue(card) {
  if (card.rank === 5) return 5;
  if (card.rank === 10 || card.rank === 13) return 10;
  return 0;
}
// 底分:喊 100 → 100,每多 10 分多 100
export function baseStake(contract) { return (contract - 90) * 10; }

function removeCards(hand, cards) {
  const ids = new Set(cards.map(c => c.id));
  return hand.filter(c => !ids.has(c.id));
}

export class Game {
  constructor({ players = 4, humanSeat = 0, rng = Math.random } = {}) {
    this.players = players;
    this.humanSeat = humanSeat;
    this.rng = rng;
    this.scores = new Array(players).fill(0);     // 累计积分
    this.firstBidder = Math.floor(rng() * players); // 第一局随机起喊
    this.handNo = 0;
  }

  startHand() {
    this.handNo++;
    const d = deal(shuffle(buildDeck(), this.rng), this.players);
    this.hands = d.hands.map(h => h.slice());
    this.kitty = d.kitty;
    this.kittySize = d.kittySize;
    this.buried = null;
    this.trumpSuit = null;
    this.declarer = null;
    this.contract = null;
    this.phase = 'bidding';
    this.highBid = null;
    this.highBidder = null;
    this.passed = new Array(this.players).fill(false);
    this.bidTurn = this.firstBidder;
    this.xianPoints = 0;
    this.xianCaptured = [];      // 闲家捡到的分数牌
    this.lastTrickBonus = 0;
    this.tricks = [];
    this.trickPlays = [];
    this.leadCombo = null;
    this.leader = null;
    this.turn = null;
    this.result = null;
    return this;
  }

  // ---------- 喊分(多轮拍卖:往上加价,到 200 或其余都放弃才结束)----------
  nextBidLevel() { return this.highBid == null ? 100 : Math.min(200, this.highBid + 10); }

  placeBid(seat, amount) {
    if (this.phase !== 'bidding') throw new Error('非喊分阶段');
    if (seat !== this.bidTurn) throw new Error('未轮到该家喊分');
    if (amount != null) {
      if (amount % 10 !== 0 || amount < 100 || amount > 200 || amount <= (this.highBid ?? 90))
        throw new Error('喊分必须是 100~200、10 的倍数、且高于当前最高');
      this.highBid = amount;
      this.highBidder = seat;
    } else {
      this.passed[seat] = true;       // 放弃后本局不再参与
    }
    if (this.highBid === 200) return this._finishBidding();   // 到顶,直接坐庄
    // 找下一个有资格的人:还没放弃、且不是当前最高者(最高者无须再加价)
    for (let i = 1; i <= this.players; i++) {
      const c = (seat + i) % this.players;
      if (!this.passed[c] && c !== this.highBidder) { this.bidTurn = c; return; }
    }
    this._finishBidding();            // 其余都已放弃
  }

  _finishBidding() {
    this.declarer = this.highBidder != null ? this.highBidder : this.firstBidder;
    this.contract = this.highBid != null ? this.highBid : 100;
    this.phase = 'declare';
  }

  // ---------- 亮主 + 扣底 ----------
  declareTrump(suit) {
    if (this.phase !== 'declare') throw new Error('非亮主阶段');
    this.trumpSuit = suit;
    this.hands[this.declarer] = this.hands[this.declarer].concat(this.kitty); // 庄家拿底牌
    this.phase = 'kitty';
  }

  buryCards(cards) {
    if (this.phase !== 'kitty') throw new Error('非扣底阶段');
    if (cards.length !== this.kittySize) throw new Error('扣底数量不对');
    this.hands[this.declarer] = removeCards(this.hands[this.declarer], cards);
    this.buried = cards.slice();
    this.phase = 'play';
    this.leader = this.turn = this.declarer; // 庄家首攻
    this.trickPlays = [];
    this.leadCombo = null;
  }

  // ---------- 出牌 ----------
  isLeadTurn() { return this.trickPlays.length === 0; }

  validatePlay(seat, cards) {
    if (this.phase !== 'play' || seat !== this.turn) return false;
    if (!cards.length) return false;
    const ids = new Set(this.hands[seat].map(c => c.id));
    if (!cards.every(c => ids.has(c.id))) return false;
    // 首攻:单/对/拖拉机,或"必大"主牌甩牌
    if (this.isLeadTurn()) return !!detectCombo(cards, this.trumpSuit) || this.validThrow(seat, cards);
    return isLegalFollow(this.hands[seat], this.leadCombo, cards, this.trumpSuit);
  }

  // 甩牌合法性:多张主牌,且未见的主里没有任何一张能大过甩出的最小者(必赢)。
  // 底牌里的主也按"未见"算 → 偏保守,但绝不会甩输。
  validThrow(seat, cards) {
    if (cards.length < 2) return false;
    if (!cards.every(c => isTrump(c, this.trumpSuit))) return false; // 只允许甩主牌(副牌不准甩)
    const minS = Math.min(...cards.map(c => strength(c, this.trumpSuit)));
    const seen = [];
    for (const tr of this.tricks) for (const p of tr.plays) seen.push(...p.cards);
    for (const p of this.trickPlays) seen.push(...p.cards);
    // 主牌组全部候选:王 + 所有 3/2 + 主花色 4..A
    const cands = [{ suit: 'JOKER', rank: 17 }, { suit: 'JOKER', rank: 16 }];
    for (const s of ['S', 'H', 'D', 'C']) cands.push({ suit: s, rank: 3 }, { suit: s, rank: 2 });
    for (let r = 4; r <= 14; r++) cands.push({ suit: this.trumpSuit, rank: r });
    const hand = this.hands[seat];
    for (const cand of cands) {
      if (strength(cand, this.trumpSuit) <= minS) continue;
      let copies = 2;
      copies -= seen.filter(c => c.suit === cand.suit && c.rank === cand.rank).length;
      copies -= hand.filter(c => c.suit === cand.suit && c.rank === cand.rank).length;
      if (copies > 0) return false;
    }
    return true;
  }

  playCards(seat, cards) {
    if (!this.validatePlay(seat, cards)) throw new Error('出牌不合法');
    let combo = detectCombo(cards, this.trumpSuit);
    if (this.isLeadTurn()) {
      if (!combo) {
        // 甩牌 Combo(同强度的跟牌压不过它 → 必归首家)
        combo = { type: 'throw', length: cards.length, group: 'TRUMP', top: Math.max(...cards.map(c => strength(c, this.trumpSuit))) };
      }
      this.leadCombo = combo;
    }
    this.hands[seat] = removeCards(this.hands[seat], cards);
    this.trickPlays.push({ seat, cards: cards.slice(), combo });
    if (this.trickPlays.length === this.players) this._resolveTrick();
    else this.turn = (this.turn + 1) % this.players;
  }

  _resolveTrick() {
    const widx = resolveTrick(this.trickPlays, this.trumpSuit);
    const win = this.trickPlays[widx];
    const pts = this.trickPlays.reduce((s, p) => s + p.cards.reduce((a, c) => a + pointValue(c), 0), 0);
    const isXian = win.seat !== this.declarer;
    if (isXian) {
      this.xianPoints += pts;
      for (const p of this.trickPlays)
        for (const c of p.cards) if (pointValue(c)) this.xianCaptured.push(c); // 记录捡到的分牌
    }

    const handsEmpty = this.hands.every(h => h.length === 0);
    if (handsEmpty && isXian && win.combo && win.combo.group === 'TRUMP') {
      // 底牌捡分:最后一墩闲家用主牌赢 → 翻底捡分;对子/拖拉机 ×2,单牌 ×1
      const kp = this.buried.reduce((a, c) => a + pointValue(c), 0);
      const mult = (win.combo.type === 'single' || win.combo.type === 'throw') ? 1 : 2; // 甩牌是单牌集合,不翻倍
      this.lastTrickBonus = kp * mult;
      this.xianPoints += this.lastTrickBonus;
      for (const c of this.buried) if (pointValue(c)) this.xianCaptured.push(c);
    }

    this.tricks.push({ plays: this.trickPlays, winnerSeat: win.seat, points: pts });
    this.trickPlays = [];
    this.leader = this.turn = win.seat;
    this.leadCombo = null;
    if (handsEmpty) this._finishHand();
  }

  // ---------- 结算 ----------
  _finishHand() {
    const L = 200 - this.contract;
    const x = this.xianPoints;
    let perXian; // 闲家视角的底数(正=闲家赢,负=闲家输)
    let label;
    if (x === 0) { perXian = -2; label = '庄家光头'; }
    else if (x < L) { perXian = -1; label = '庄家赢'; }
    else if (x === L) { perXian = 0; label = '平手'; }
    else { perXian = 1 + Math.floor((x - L - 1) / 30); label = `闲家赢(${perXian}档)`; }

    const stake = baseStake(this.contract);
    const deltas = new Array(this.players).fill(0);
    let zhuang = 0;
    for (let s = 0; s < this.players; s++) {
      if (s === this.declarer) continue;
      deltas[s] = perXian * stake;
      zhuang -= perXian * stake;
    }
    deltas[this.declarer] = zhuang;
    for (let s = 0; s < this.players; s++) this.scores[s] += deltas[s];

    // 下局起喊:庄家输(闲家赢)→ 庄家下家;否则庄家
    this.firstBidder = (x > L) ? (this.declarer + 1) % this.players : this.declarer;

    this.result = {
      declarer: this.declarer, contract: this.contract, line: L,
      xianPoints: x, lastTrickBonus: this.lastTrickBonus,
      label, perXian, stake, deltas, scores: this.scores.slice(),
    };
    this.phase = 'done';
  }
}
