// engine_test.go — 规则内核测试(移植自 test/engine.test.js)
package game

import "testing"

func C(suit string, rank int, copy ...int) Card {
	cp := 0
	if len(copy) > 0 {
		cp = copy[0]
	}
	return MakeCard(suit, rank, cp)
}
func J(big bool, copy ...int) Card {
	cp := 0
	if len(copy) > 0 {
		cp = copy[0]
	}
	r := SmallJoker
	if big {
		r = BigJoker
	}
	return MakeCard("JOKER", r, cp)
}

const T = "S" // 主花色 ♠

func TestDeck(t *testing.T) {
	if n := len(BuildDeck()); n != 108 {
		t.Fatalf("两副共 108 张, got %d", n)
	}
	jok := 0
	for _, c := range BuildDeck() {
		if c.IsJoker() {
			jok++
		}
	}
	if jok != 4 {
		t.Fatalf("共 4 张王, got %d", jok)
	}
}

func TestDeal(t *testing.T) {
	d4 := Deal(BuildDeck(), 4)
	if len(d4.Hands) != 4 || len(d4.Kitty) != 8 {
		t.Fatalf("4人:每人25、底牌8")
	}
	for _, h := range d4.Hands {
		if len(h) != 25 {
			t.Fatalf("4人每人25, got %d", len(h))
		}
	}
	d3 := Deal(BuildDeck(), 3)
	if len(d3.Hands) != 3 || len(d3.Kitty) != 9 {
		t.Fatalf("3人:每人33、底牌9")
	}
	for _, h := range d3.Hands {
		if len(h) != 33 {
			t.Fatalf("3人每人33, got %d", len(h))
		}
	}
}

func TestPermanentTrumps(t *testing.T) {
	if !IsTrump(C("S", 5), T) {
		t.Error("♠5 是主(主花色)")
	}
	if !IsTrump(C("H", 3), T) {
		t.Error("♥3 是主(常主 3)")
	}
	if !IsTrump(C("H", 2), T) {
		t.Error("♥2 是主(常主 2)")
	}
	if IsTrump(C("H", 7), T) {
		t.Error("♥7 不是主(7 普通)")
	}
	if !IsTrump(J(true), T) {
		t.Error("大王是主")
	}
}

func TestStrength(t *testing.T) {
	order := []Card{J(true), J(false), C("S", 3), C("S", 2), C("S", 14), C("S", 7), C("S", 4)}
	for i := 1; i < len(order); i++ {
		if Strength(order[i-1], T) <= Strength(order[i], T) {
			t.Fatalf("主牌顺序第 %d 处未递减", i)
		}
	}
	if Strength(C("S", 3), T) <= Strength(C("H", 3), T) {
		t.Error("主3 > 副3")
	}
	if Strength(C("S", 2), T) <= Strength(C("H", 2), T) {
		t.Error("主2 > 副2")
	}
	if Strength(C("H", 3), T) <= Strength(C("S", 2), T) {
		t.Error("所有 3 > 所有 2(副3 > 主2)")
	}
	// 单张 主3 > 主K(♥主:♥3 压 ♥K)
	k3 := DetectCombo([]Card{C("H", 3)}, "H")
	kk := DetectCombo([]Card{C("H", 13)}, "H")
	if !Beats(k3, kk) {
		t.Error("♥主时 ♥3 压 ♥K")
	}
	if Strength(C("D", 3), T) != Strength(C("C", 3), T) {
		t.Error("副3 大小相同(♦3 = ♣3)")
	}
	if Strength(C("H", 7), T) != 7 {
		t.Error("♥7 边牌强度 = 7")
	}
}

func TestDetectCombo(t *testing.T) {
	cases := []struct {
		name  string
		cards []Card
		trump string
		want  string // "" = nil
	}{
		{"单张", []Card{C("S", 5)}, T, "single"},
		{"对子 ♠5♠5", []Card{C("S", 5, 0), C("S", 5, 1)}, T, "pair"},
		{"♥3+♦3 不是对子(副主跨花色)", []Card{C("H", 3), C("D", 3)}, T, ""},
		{"5566 是拖拉机", []Card{C("H", 5, 0), C("H", 5, 1), C("H", 6, 0), C("H", 6, 1)}, T, "tractor"},
		{"6677 是拖拉机(7 普通)", []Card{C("H", 6, 0), C("H", 6, 1), C("H", 7, 0), C("H", 7, 1)}, T, "tractor"},
		{"6688 不是拖拉机", []Card{C("H", 6, 0), C("H", 6, 1), C("H", 8, 0), C("H", 8, 1)}, T, ""},
		{"大王大王+小王小王 是拖拉机", []Card{J(true, 0), J(true, 1), J(false, 0), J(false, 1)}, T, "tractor"},
		{"主3主3+小王小王 不是拖拉机(王孤岛)", []Card{C("S", 3, 0), C("S", 3, 1), J(false, 0), J(false, 1)}, T, ""},
		{"♥3♥3+♦3♦3 不是拖拉机(副主同级)", []Card{C("H", 3, 0), C("H", 3, 1), C("D", 3, 0), C("D", 3, 1)}, T, ""},
		{"♠3♠3+♥3♥3 不是拖拉机", []Card{C("S", 3, 0), C("S", 3, 1), C("H", 3, 0), C("H", 3, 1)}, T, ""},
		{"♠3♠3+♠2♠2 是拖拉机(3 与 2 相邻)", []Card{C("S", 3, 0), C("S", 3, 1), C("S", 2, 0), C("S", 2, 1)}, T, "tractor"},
		{"♥3♥3+♥2♥2 是拖拉机(♥ 主)", []Card{C("H", 3, 0), C("H", 3, 1), C("H", 2, 0), C("H", 2, 1)}, "H", "tractor"},
		{"♥3♥3+♥4♥4 是拖拉机(自然 3-4)", []Card{C("H", 3, 0), C("H", 3, 1), C("H", 4, 0), C("H", 4, 1)}, "H", "tractor"},
		{"♥A♥A+♥2♥2 是拖拉机(主A 接 2)", []Card{C("H", 14, 0), C("H", 14, 1), C("H", 2, 0), C("H", 2, 1)}, "H", "tractor"},
		{"♥A♥A+♥K♥K 是拖拉机(主A 也接 K)", []Card{C("H", 14, 0), C("H", 14, 1), C("H", 13, 0), C("H", 13, 1)}, "H", "tractor"},
		{"♥K♥K+♥A♥A+♥2♥2 不是拖拉机(A 不桥接)", []Card{C("H", 13, 0), C("H", 13, 1), C("H", 14, 0), C("H", 14, 1), C("H", 2, 0), C("H", 2, 1)}, "H", ""},
		{"♥3♥3+♦2♦2 不是拖拉机(跨花色)", []Card{C("H", 3, 0), C("H", 3, 1), C("D", 2, 0), C("D", 2, 1)}, "H", ""},
	}
	for _, tc := range cases {
		got := DetectCombo(tc.cards, tc.trump)
		if tc.want == "" {
			if got != nil {
				t.Errorf("%s: 应为 nil, got %+v", tc.name, got)
			}
		} else if got == nil || got.Type != tc.want {
			t.Errorf("%s: 应为 %s, got %+v", tc.name, tc.want, got)
		}
	}
}

func TestBeatsAndTrick(t *testing.T) {
	a := DetectCombo([]Card{C("H", 9, 0), C("H", 9, 1)}, T)
	b := DetectCombo([]Card{C("S", 4, 0), C("S", 4, 1)}, T)
	if !Beats(b, a) {
		t.Error("主牌对子杀边牌对子")
	}
	b2 := DetectCombo([]Card{C("H", 11, 0), C("H", 11, 1)}, T)
	if !Beats(b2, a) {
		t.Error("同花色大对压小对")
	}
	b3 := DetectCombo([]Card{C("D", 13, 0), C("D", 13, 1)}, T)
	if Beats(b3, a) {
		t.Error("不同边花色压不过")
	}
	w := ResolveTrick([][]Card{{C("H", 9)}, {C("S", 4)}, {C("H", 14)}}, T)
	if w != 1 {
		t.Errorf("收墩:♠4 杀 → 下标1, got %d", w)
	}
}
