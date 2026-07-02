// combos.go — 牌型识别、压牌比较、收墩判定(移植自 src/combos.js)
package game

import (
	"sort"
	"strconv"
)

// (花色,点数) 键 —— 同键的两张即一对
func cardKey(c Card) string { return c.Suit + "-" + strconv.Itoa(c.Rank) }

// Combo 识别结果。Type: "single"|"pair"|"tractor"
type Combo struct {
	Type   string `json:"type"`
	Length int    `json:"length"`
	Group  string `json:"group"`
	Top    int    `json:"top"`
	Pairs  int    `json:"pairs,omitempty"`
}

// 一组阶梯位是否连成一条拖拉机(排序后相邻差恰为 1,无重复)
func isConsecutive(positions []int) bool {
	s := append([]int(nil), positions...)
	sort.Ints(s)
	for i := 1; i < len(s); i++ {
		if s[i]-s[i-1] != 1 {
			return false
		}
	}
	return true
}

// 按牌的出现顺序收集 (suit,rank) 键 → 代表牌与张数(保持插入顺序,与 JS Map 一致)
type keyEntry struct {
	card  Card
	count int
}

func orderedByKey(cards []Card) []keyEntry {
	idx := map[string]int{}
	var out []keyEntry
	for _, c := range cards {
		k := cardKey(c)
		if i, ok := idx[k]; ok {
			out[i].count++
		} else {
			idx[k] = len(out)
			out = append(out, keyEntry{card: c, count: 1})
		}
	}
	return out
}

// DetectCombo 识别牌型;非法/混合组返回 nil
func DetectCombo(cards []Card, trumpSuit string) *Combo {
	if len(cards) == 0 {
		return nil
	}
	group := CardGroup(cards[0], trumpSuit)
	for _, c := range cards {
		if CardGroup(c, trumpSuit) != group {
			return nil // 单一牌型必须同组
		}
	}

	if len(cards) == 1 {
		return &Combo{Type: "single", Length: 1, Group: group, Top: Strength(cards[0], trumpSuit)}
	}

	// 配对:同花色同点数,且每种恰好 2 张
	entries := orderedByKey(cards)
	for _, e := range entries {
		if e.count != 2 {
			return nil
		}
	}

	top := 0
	for _, e := range entries {
		if s := Strength(e.card, trumpSuit); s > top {
			top = s
		}
	}

	if len(cards) == 2 {
		return &Combo{Type: "pair", Length: 2, Group: group, Top: top}
	}

	// 拖拉机:各对子按「相邻刻度」连续,且同 lane(同花色/同孤岛)
	ranks := make([]TRank, len(entries))
	for i, e := range entries {
		ranks[i] = TractorRankOf(e.card, trumpSuit)
	}
	lane := ranks[0].Lane
	for _, r := range ranks {
		if r.Lane != lane {
			return nil
		}
	}
	// 主 A 有两个可选阶梯位(接 2 或接 K),同 lane 最多一对 A → 试每种取位能否连成
	var fixed []int
	var flex *TRank
	for i := range ranks {
		if ranks[i].Alt != 0 && flex == nil {
			flex = &ranks[i]
		} else {
			fixed = append(fixed, ranks[i].Pos)
		}
	}
	linked := false
	if flex != nil {
		linked = isConsecutive(append(append([]int(nil), fixed...), flex.Pos)) ||
			isConsecutive(append(append([]int(nil), fixed...), flex.Alt))
	} else {
		linked = isConsecutive(fixed)
	}
	if !linked {
		return nil
	}
	return &Combo{Type: "tractor", Length: len(cards), Group: group, Pairs: len(ranks), Top: top}
}

// Beats b 能否压过 a(a 为当前最大,b 为新出)。两者需同型同长。
func Beats(b, a *Combo) bool {
	if b == nil || a == nil {
		return false
	}
	if b.Type != a.Type || b.Length != a.Length {
		return false
	}
	if a.Group == "TRUMP" {
		return b.Group == "TRUMP" && b.Top > a.Top
	}
	if b.Group == "TRUMP" {
		return true // 用主牌杀边牌
	}
	if b.Group == a.Group {
		return b.Top > a.Top // 同花色比大小
	}
	return false // 不同边花色:垫牌,压不过
}

// ResolveTrick 一墩收谁。plays 第 0 个为首攻,返回获胜下标。
func ResolveTrick(plays [][]Card, trumpSuit string) int {
	winner := 0
	best := DetectCombo(plays[0], trumpSuit)
	for i := 1; i < len(plays); i++ {
		c := DetectCombo(plays[i], trumpSuit)
		if Beats(c, best) {
			winner = i
			best = c
		}
	}
	return winner
}
