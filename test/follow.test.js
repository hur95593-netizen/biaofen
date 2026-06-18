// test/follow.test.js — 跟牌 + 跟大 测试(node test/follow.test.js)
import assert from 'assert';
import { makeCard, BIG_JOKER, SMALL_JOKER } from '../src/cards.js';
import { detectCombo } from '../src/combos.js';
import { isLegalFollow } from '../src/follow.js';

let pass = 0, fail = 0;
function test(name, fn) {
  try { fn(); pass++; console.log('  ✓ ' + name); }
  catch (e) { fail++; console.log('  ✗ ' + name + '\n      → ' + e.message); }
}
const C = (suit, rank, copy = 0) => makeCard(suit, rank, copy);
const J = (big, copy = 0) => makeCard('JOKER', big ? BIG_JOKER : SMALL_JOKER, copy);
const T = 'S'; // 主花色 ♠;♥♦♣ 为边
const ok = (...a) => assert.ok(isLegalFollow(...a));
const no = (...a) => assert.ok(!isLegalFollow(...a));

console.log('— 对子:有对必须跟对 —');
{
  const hand = [C('H', 9, 0), C('H', 9, 1), C('H', 10, 0), C('H', 11, 0)];
  const lead = detectCombo([C('H', 4, 0), C('H', 4, 1)], T); // ♥ 对子
  test('跟对子合法', () => ok(hand, lead, [C('H', 9, 0), C('H', 9, 1)], T));
  test('有对却拆成两单 → 非法', () => no(hand, lead, [C('H', 9, 0), C('H', 10, 0)], T));
}

console.log('— 对子:边牌无对,任意两张单 —');
{
  const hand = [C('H', 9, 0), C('H', 10, 0), C('H', 11, 0), C('H', 13, 0)];
  const lead = detectCombo([C('H', 4, 0), C('H', 4, 1)], T);
  test('边牌随便两张单', () => ok(hand, lead, [C('H', 9, 0), C('H', 11, 0)], T));
}

console.log('— 对子:主牌无对,跟大(最大两张)—');
{
  // 主♠手牌:小王(117)、♠K(110)、♠5(102),无对
  const hand = [J(false, 0), C('S', 13, 0), C('S', 5, 0)];
  const lead = detectCombo([C('S', 6, 0), C('S', 6, 1)], T); // 主牌对子
  test('出最大两张(小王+♠K)合法', () => ok(hand, lead, [J(false, 0), C('S', 13, 0)], T));
  test('藏起♠K(♠K+♠5)→ 非法', () => no(hand, lead, [C('S', 13, 0), C('S', 5, 0)], T));
  test('藏起♠K(小王+♠5)→ 非法', () => no(hand, lead, [J(false, 0), C('S', 5, 0)], T));
}

console.log('— 对子:主牌有对,必须跟对(不是跟大单)—');
{
  const hand = [C('S', 5, 0), C('S', 5, 1), J(false, 0)];
  const lead = detectCombo([C('S', 6, 0), C('S', 6, 1)], T);
  test('跟对 ♠5♠5 合法', () => ok(hand, lead, [C('S', 5, 0), C('S', 5, 1)], T));
  test('有对却出 小王+♠5 → 非法', () => no(hand, lead, [J(false, 0), C('S', 5, 0)], T));
}

console.log('— 拖拉机:跟大单牌(飙分里 主3 很大)—');
{
  // 主♠手牌:♠Q♠Q(对) + 小王(117)+♠3(主3=115)+♠5(102)
  const hand = [C('S', 12, 0), C('S', 12, 1), J(false, 0), C('S', 5, 0), C('S', 3, 0)];
  const lead = detectCombo([C('S', 14, 0), C('S', 14, 1), C('S', 13, 0), C('S', 13, 1)], T); // ♠A♠A♠K♠K
  test('♠Q♠Q + 小王 + ♠3(最大两单)合法', () =>
    ok(hand, lead, [C('S', 12, 0), C('S', 12, 1), J(false, 0), C('S', 3, 0)], T));
  test('♠Q♠Q + 小王 + ♠5(漏了更大的♠3)→ 非法', () =>
    no(hand, lead, [C('S', 12, 0), C('S', 12, 1), J(false, 0), C('S', 5, 0)], T));
  test('不出对子(拆 ♠Q)→ 非法', () =>
    no(hand, lead, [C('S', 12, 0), J(false, 0), C('S', 3, 0), C('S', 5, 0)], T));
}

console.log('— 拖拉机:有等长拖拉机必须跟拖拉机 —');
{
  // 边♥:♥7♥7+♥8♥8(连=2拖)、♥J♥J(单独对)
  const hand = [C('H', 7, 0), C('H', 7, 1), C('H', 8, 0), C('H', 8, 1), C('H', 11, 0), C('H', 11, 1)];
  const lead = detectCombo([C('H', 5, 0), C('H', 5, 1), C('H', 6, 0), C('H', 6, 1)], T); // ♥5566 拖拉机
  test('跟 ♥7788 拖拉机合法', () =>
    ok(hand, lead, [C('H', 7, 0), C('H', 7, 1), C('H', 8, 0), C('H', 8, 1)], T));
  test('有拖拉机却出 ♥77+♥JJ(不连)→ 非法', () =>
    no(hand, lead, [C('H', 7, 0), C('H', 7, 1), C('H', 11, 0), C('H', 11, 1)], T));
}

console.log('— 跟花色:有该花色必须跟,没有可垫/杀 —');
{
  const lead = detectCombo([C('H', 4, 0), C('H', 4, 1)], T); // ♥ 对子
  const noHearts = [C('S', 4, 0), C('S', 4, 1), C('D', 9, 0)];
  test('没♥:用主♠对子杀,合法', () => ok(noHearts, lead, [C('S', 4, 0), C('S', 4, 1)], T));
  test('没♥:垫两张杂牌,合法', () => ok(noHearts, lead, [C('S', 4, 0), C('D', 9, 0)], T));

  const hasHearts = [C('H', 9, 0), C('H', 10, 0), C('S', 4, 0), C('S', 4, 1)];
  test('有♥却用主牌(不跟花色)→ 非法', () => no(hasHearts, lead, [C('S', 4, 0), C('S', 4, 1)], T));
  test('有♥就跟两张♥,合法', () => ok(hasHearts, lead, [C('H', 9, 0), C('H', 10, 0)], T));
}

console.log(`\n结果:${pass} 通过, ${fail} 失败`);
if (fail) process.exit(1);
