// test/sim.js — 全 AI 自动对局,验证一整局流程跑得通、算得对
// 用法:node test/sim.js [局数] [人数]
import { Game } from '../src/game.js';
import { cardLabel } from '../src/cards.js';
import * as AI from '../src/ai.js';

function mulberry32(a) {
  return function () {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}

function playOneHand(g) {
  g.startHand();
  let guard = 0;
  while (g.phase === 'bidding') { g.placeBid(g.bidTurn, AI.aiBid(g, g.bidTurn)); if (++guard > 50) throw new Error('喊分死循环'); }
  g.declareTrump(AI.aiTrump(g, g.declarer));
  g.buryCards(AI.aiBury(g, g.declarer));
  guard = 0;
  while (g.phase === 'play') {
    const seat = g.turn;
    const cards = g.isLeadTurn() ? AI.aiLead(g, seat) : AI.aiFollow(g, seat);
    g.playCards(seat, cards);
    if (++guard > 10000) throw new Error('出牌死循环');
  }
  return g.result;
}

const N = parseInt(process.argv[2] || '200', 10);
const players = parseInt(process.argv[3] || '4', 10);
const g = new Game({ players, rng: mulberry32(99) });

let hands = 0, draws = 0, zhuangWins = 0, xianWins = 0, baldies = 0;
let sample = null;
let sumC = 0, sumX = 0;
for (let i = 0; i < N; i++) {
  const r = playOneHand(g);
  hands++; sumC += r.contract; sumX += r.xianPoints;
  if (r.perXian === 0) draws++;
  else if (r.perXian < 0) { zhuangWins++; if (r.xianPoints === 0) baldies++; }
  else xianWins++;
  if (i === 0) sample = { g, r };
}

// 打印第一局细节作为抽样检查
const r = sample.r;
console.log('=== 抽样:第 1 局 ===');
console.log(`庄家: P${r.declarer}  喊分: ${r.contract}  闲家线(L=200-喊分): ${r.line}`);
console.log(`闲家捡分: ${r.xianPoints}（含底牌捡分 ${r.lastTrickBonus}）  →  ${r.label}`);
console.log(`底分/喊分: ${r.stake}  本局结算(各座位积分变化): [${r.deltas.join(', ')}]`);
console.log(`结算守恒(应为0): ${r.deltas.reduce((a, b) => a + b, 0)}`);

console.log(`\n=== ${N} 局统计(${players} 人) ===`);
console.log(`庄家赢: ${zhuangWins}（其中光头 ${baldies}）   闲家赢: ${xianWins}   平手: ${draws}`);
console.log(`平均喊分: ${(sumC / N).toFixed(1)}   平均闲家线 L: ${(200 - sumC / N).toFixed(1)}   平均闲家捡分: ${(sumX / N).toFixed(1)}`);
console.log(`累计积分: [${g.scores.join(', ')}]  总和(应为0): ${g.scores.reduce((a, b) => a + b, 0)}`);
console.log('\n✅ 跑完 ' + N + ' 局,流程与结算未报错');
