// follow_test.go — 跟牌 + 跟大 测试(移植自 test/follow.test.js;主花色 ♠)
package game

import "testing"

func lf(hand []Card, lead *Combo, play []Card) bool {
	return IsLegalFollow(hand, lead, play, T)
}

func TestFollowPair(t *testing.T) {
	// 有对必须跟对
	hand := []Card{C("H", 9, 0), C("H", 9, 1), C("H", 10, 0), C("H", 11, 0)}
	lead := DetectCombo([]Card{C("H", 4, 0), C("H", 4, 1)}, T)
	if !lf(hand, lead, []Card{C("H", 9, 0), C("H", 9, 1)}) {
		t.Error("跟对子合法")
	}
	if lf(hand, lead, []Card{C("H", 9, 0), C("H", 10, 0)}) {
		t.Error("有对却拆成两单 → 非法")
	}
	// 边牌无对,任意两张单
	hand2 := []Card{C("H", 9, 0), C("H", 10, 0), C("H", 11, 0), C("H", 13, 0)}
	if !lf(hand2, lead, []Card{C("H", 9, 0), C("H", 11, 0)}) {
		t.Error("边牌随便两张单")
	}
}

func TestFollowPairTrumpTopTwo(t *testing.T) {
	// 主牌无对,跟大(最大两张)
	hand := []Card{J(false, 0), C("S", 13, 0), C("S", 5, 0)}
	lead := DetectCombo([]Card{C("S", 6, 0), C("S", 6, 1)}, T)
	if !lf(hand, lead, []Card{J(false, 0), C("S", 13, 0)}) {
		t.Error("出最大两张(小王+♠K)合法")
	}
	if lf(hand, lead, []Card{C("S", 13, 0), C("S", 5, 0)}) {
		t.Error("藏起小王 → 非法")
	}
	if lf(hand, lead, []Card{J(false, 0), C("S", 5, 0)}) {
		t.Error("藏起♠K → 非法")
	}
	// 主牌有对,必须跟对(不是跟大单)
	hand2 := []Card{C("S", 5, 0), C("S", 5, 1), J(false, 0)}
	if !lf(hand2, lead, []Card{C("S", 5, 0), C("S", 5, 1)}) {
		t.Error("跟对 ♠5♠5 合法")
	}
	if lf(hand2, lead, []Card{J(false, 0), C("S", 5, 0)}) {
		t.Error("有对却出 小王+♠5 → 非法")
	}
}

func TestFollowTractorTopSingles(t *testing.T) {
	// 拖拉机:跟大单牌(飙分里 主3 很大)
	hand := []Card{C("S", 12, 0), C("S", 12, 1), J(false, 0), C("S", 5, 0), C("S", 3, 0)}
	lead := DetectCombo([]Card{C("S", 14, 0), C("S", 14, 1), C("S", 13, 0), C("S", 13, 1)}, T)
	if !lf(hand, lead, []Card{C("S", 12, 0), C("S", 12, 1), J(false, 0), C("S", 3, 0)}) {
		t.Error("♠Q♠Q + 小王 + ♠3(最大两单)合法")
	}
	if lf(hand, lead, []Card{C("S", 12, 0), C("S", 12, 1), J(false, 0), C("S", 5, 0)}) {
		t.Error("漏了更大的♠3 → 非法")
	}
	if lf(hand, lead, []Card{C("S", 12, 0), J(false, 0), C("S", 3, 0), C("S", 5, 0)}) {
		t.Error("不出对子(拆 ♠Q)→ 非法")
	}
}

func TestFollowTractorMustTractor(t *testing.T) {
	// 有等长拖拉机必须跟拖拉机
	hand := []Card{C("H", 7, 0), C("H", 7, 1), C("H", 8, 0), C("H", 8, 1), C("H", 11, 0), C("H", 11, 1)}
	lead := DetectCombo([]Card{C("H", 5, 0), C("H", 5, 1), C("H", 6, 0), C("H", 6, 1)}, T)
	if !lf(hand, lead, []Card{C("H", 7, 0), C("H", 7, 1), C("H", 8, 0), C("H", 8, 1)}) {
		t.Error("跟 ♥7788 拖拉机合法")
	}
	if lf(hand, lead, []Card{C("H", 7, 0), C("H", 7, 1), C("H", 11, 0), C("H", 11, 1)}) {
		t.Error("有拖拉机却出 ♥77+♥JJ → 非法")
	}
}

func TestFollowSuit(t *testing.T) {
	// 有该花色必须跟,没有可垫/杀
	lead := DetectCombo([]Card{C("H", 4, 0), C("H", 4, 1)}, T)
	noHearts := []Card{C("S", 4, 0), C("S", 4, 1), C("D", 9, 0)}
	if !lf(noHearts, lead, []Card{C("S", 4, 0), C("S", 4, 1)}) {
		t.Error("没♥:用主♠对子杀,合法")
	}
	if !lf(noHearts, lead, []Card{C("S", 4, 0), C("D", 9, 0)}) {
		t.Error("没♥:垫两张杂牌,合法")
	}
	hasHearts := []Card{C("H", 9, 0), C("H", 10, 0), C("S", 4, 0), C("S", 4, 1)}
	if lf(hasHearts, lead, []Card{C("S", 4, 0), C("S", 4, 1)}) {
		t.Error("有♥却用主牌 → 非法")
	}
	if !lf(hasHearts, lead, []Card{C("H", 9, 0), C("H", 10, 0)}) {
		t.Error("有♥就跟两张♥,合法")
	}
}
