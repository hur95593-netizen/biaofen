// test/engine.test.js — 规则内核测试(node test/engine.test.js)
import assert from 'assert';
import {
  buildDeck, deal, isTrump, strength, makeCard, isJoker,
  BIG_JOKER, SMALL_JOKER,
} from '../src/cards.js';
import { detectCombo, beats, resolveTrick } from '../src/combos.js';

let pass = 0, fail = 0;
function test(name, fn) {
  try { fn(); pass++; console.log('  ✓ ' + name); }
  catch (e) { fail++; console.log('  ✗ ' + name + '\n      → ' + e.message); }
}

const C = (suit, rank, copy = 0) => makeCard(suit, rank, copy);
const J = (big, copy = 0) => makeCard('JOKER', big ? BIG_JOKER : SMALL_JOKER, copy);
const T = 'S'; // 主花色 ♠

console.log('— 牌组 —');
test('两副共 108 张', () => assert.strictEqual(buildDeck().length, 108));
test('共 4 张王', () => assert.strictEqual(buildDeck().filter(isJoker).length, 4));

console.log('— 发牌 —');
test('4 人:每人 25、底牌 8', () => {
  const { hands, kitty } = deal(buildDeck(), 4);
  assert.strictEqual(hands.length, 4);
  assert.ok(hands.every(h => h.length === 25));
  assert.strictEqual(kitty.length, 8);
});
test('3 人:每人 33、底牌 9', () => {
  const { hands, kitty } = deal(buildDeck(), 3);
  assert.strictEqual(hands.length, 3);
  assert.ok(hands.every(h => h.length === 33));
  assert.strictEqual(kitty.length, 9);
});

console.log('— 常主 王/3/2;7 是普通牌 —');
test('♠5 是主(主花色)', () => assert.ok(isTrump(C('S', 5), T)));
test('♥3 是主(常主 3)', () => assert.ok(isTrump(C('H', 3), T)));
test('♥2 是主(常主 2)', () => assert.ok(isTrump(C('H', 2), T)));
test('♥7 不是主(7 普通)', () => assert.ok(!isTrump(C('H', 7), T)));
test('大王是主', () => assert.ok(isTrump(J(true), T)));

console.log('— 主牌大小:大王>小王>主3>副3>主2>副2>主A>…>主4 —');
test('主牌顺序严格递减', () => {
  const order = [J(true), J(false), C('S', 3), C('H', 3), C('S', 2), C('H', 2), C('S', 14), C('S', 7), C('S', 4)];
  const s = order.map(c => strength(c, T));
  for (let i = 1; i < s.length; i++) assert.ok(s[i - 1] > s[i], `第 ${i} 处未递减: ${s.join(',')}`);
});
test('♥7 边牌强度 = 7', () => assert.strictEqual(strength(C('H', 7), T), 7));

console.log('— 牌型识别 —');
test('单张', () => assert.strictEqual(detectCombo([C('S', 5)], T).type, 'single'));
test('对子 ♠5♠5', () => assert.strictEqual(detectCombo([C('S', 5, 0), C('S', 5, 1)], T).type, 'pair'));
test('♥3+♦3 不是对子(副主跨花色)', () => assert.strictEqual(detectCombo([C('H', 3), C('D', 3)], T), null));
test('5566 是拖拉机', () => assert.strictEqual(detectCombo([C('H', 5, 0), C('H', 5, 1), C('H', 6, 0), C('H', 6, 1)], T).type, 'tractor'));
test('6677 是拖拉机(飙分:7 普通)', () => assert.strictEqual(detectCombo([C('H', 6, 0), C('H', 6, 1), C('H', 7, 0), C('H', 7, 1)], T).type, 'tractor'));
test('6688 不是拖拉机(7 隔在中间)', () => assert.strictEqual(detectCombo([C('H', 6, 0), C('H', 6, 1), C('H', 8, 0), C('H', 8, 1)], T), null));
test('大王大王+小王小王 是拖拉机', () => assert.strictEqual(detectCombo([J(true, 0), J(true, 1), J(false, 0), J(false, 1)], T).type, 'tractor'));
test('主3主3+小王小王 不是拖拉机(王孤岛)', () => assert.strictEqual(detectCombo([C('S', 3, 0), C('S', 3, 1), J(false, 0), J(false, 1)], T), null));
test('♥3♥3+♦3♦3 不是拖拉机(副主同级)', () => assert.strictEqual(detectCombo([C('H', 3, 0), C('H', 3, 1), C('D', 3, 0), C('D', 3, 1)], T), null));
test('主3主3+副3副3 是拖拉机', () => assert.strictEqual(detectCombo([C('S', 3, 0), C('S', 3, 1), C('H', 3, 0), C('H', 3, 1)], T).type, 'tractor'));

console.log('— 压牌 / 收墩 —');
test('主牌对子杀边牌对子', () => {
  const a = detectCombo([C('H', 9, 0), C('H', 9, 1)], T);
  const b = detectCombo([C('S', 4, 0), C('S', 4, 1)], T);
  assert.ok(beats(b, a));
});
test('同花色大对压小对', () => {
  const a = detectCombo([C('H', 9, 0), C('H', 9, 1)], T);
  const b = detectCombo([C('H', 11, 0), C('H', 11, 1)], T);
  assert.ok(beats(b, a));
});
test('不同边花色压不过', () => {
  const a = detectCombo([C('H', 9, 0), C('H', 9, 1)], T);
  const b = detectCombo([C('D', 13, 0), C('D', 13, 1)], T);
  assert.ok(!beats(b, a));
});
test('收墩:首攻 ♥9,后手 ♠4 杀 → 后手(下标1)胜', () => {
  const w = resolveTrick([{ cards: [C('H', 9)] }, { cards: [C('S', 4)] }, { cards: [C('H', 14)] }], T);
  assert.strictEqual(w, 1);
});

console.log(`\n结果:${pass} 通过, ${fail} 失败`);
if (fail) process.exit(1);
