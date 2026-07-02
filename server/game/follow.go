// follow.go — 跟牌合法性(跟牌结构 + 跟大),移植自 src/follow.js
// 规则见 飙分-规则.md 第 5 节:
//   首家出什么,按 拖拉机 → 对子 → 单牌 的优先级尽量凑同结构,且必须出满该组的牌;
//   跟大:被迫拆单张主牌凑数时,单张必须是最大的;副牌不跟大。
package game

import "sort"

// PairCount 对子数:每种(花色,点数)满 2 张算 1 对
func PairCount(cards []Card) int {
	p := 0
	for _, e := range orderedByKey(cards) {
		p += e.count / 2
	}
	return p
}

// 落单牌的 strength,从大到小
func singletonStrengths(cards []Card, trumpSuit string) []int {
	var out []int
	for _, e := range orderedByKey(cards) {
		if e.count%2 == 1 {
			out = append(out, Strength(e.card, trumpSuit))
		}
	}
	sort.Sort(sort.Reverse(sort.IntSlice(out)))
	return out
}

// 一组阶梯位里的最长连续段长度
func longestRun(positions []int) int {
	seen := map[int]bool{}
	var s []int
	for _, p := range positions {
		if !seen[p] {
			seen[p] = true
			s = append(s, p)
		}
	}
	sort.Ints(s)
	if len(s) == 0 {
		return 0
	}
	best, run := 1, 1
	for i := 1; i < len(s); i++ {
		if s[i]-s[i-1] == 1 {
			run++
		} else {
			run = 1
		}
		if run > best {
			best = run
		}
	}
	return best
}

// MaxTractorLen 最长拖拉机(连续对子)长度。按「相邻刻度」分 lane 各算,主 A 两个取位都试。
func MaxTractorLen(cards []Card, trumpSuit string) int {
	type laneInfo struct {
		fixed []int
		flexA []int // [pos, alt] 或 nil
	}
	byLane := map[string]*laneInfo{}
	for _, e := range orderedByKey(cards) {
		if e.count < 2 {
			continue
		}
		r := TractorRankOf(e.card, trumpSuit)
		if byLane[r.Lane] == nil {
			byLane[r.Lane] = &laneInfo{}
		}
		L := byLane[r.Lane]
		if r.Alt != 0 {
			L.flexA = []int{r.Pos, r.Alt}
		} else {
			L.fixed = append(L.fixed, r.Pos)
		}
	}
	best := 0
	for _, L := range byLane {
		if L.flexA == nil {
			if n := longestRun(L.fixed); n > best {
				best = n
			}
		} else {
			for _, pos := range L.flexA {
				if n := longestRun(append(append([]int(nil), L.fixed...), pos)); n > best {
					best = n
				}
			}
		}
	}
	return best
}

func isPairCards(cards []Card) bool {
	return len(cards) == 2 && cards[0].Suit == cards[1].Suit && cards[0].Rank == cards[1].Rank
}

// play 是否为 hand 的子多重集(按牌 ID)
func isSubMultiset(sub, sup []Card) bool {
	have := map[string]int{}
	for _, c := range sup {
		have[c.ID]++
	}
	for _, c := range sub {
		if have[c.ID] <= 0 {
			return false
		}
		have[c.ID]--
	}
	return true
}

func sameIntMultiset(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	x := append([]int(nil), a...)
	y := append([]int(nil), b...)
	sort.Ints(x)
	sort.Ints(y)
	for i := range x {
		if x[i] != y[i] {
			return false
		}
	}
	return true
}

// 跟大:play 的落单牌必须正好是 hand 落单牌里最大的 count 张
func topSingletonsOK(playG, handG []Card, count int, trumpSuit string) bool {
	want := singletonStrengths(handG, trumpSuit)
	if len(want) > count {
		want = want[:count]
	}
	got := singletonStrengths(playG, trumpSuit)
	return len(got) == count && sameIntMultiset(want, got)
}

// IsLegalFollow play 是否为对 lead 的一手合法跟牌。lead 为 DetectCombo 结果。
// 已知简化(与 JS 版一致):当"自己最长拖拉机 < 首攻拖拉机长度"时,只强制"用满最大对子数",
// 不强制把较短的拖拉机也连着出。常见的"有等长拖拉机必须跟"已强制。
func IsLegalFollow(hand []Card, lead *Combo, play []Card, trumpSuit string) bool {
	N := lead.Length
	if len(play) != N {
		return false
	}
	if !isSubMultiset(play, hand) {
		return false
	}

	G := lead.Group
	var handG, playG []Card
	for _, c := range hand {
		if CardGroup(c, trumpSuit) == G {
			handG = append(handG, c)
		}
	}
	for _, c := range play {
		if CardGroup(c, trumpSuit) == G {
			playG = append(playG, c)
		}
	}
	m := len(handG)
	need := N
	if m < N {
		need = m
	}
	if len(playG) != need {
		return false // 必须出满该组的牌(有就得跟)
	}

	if m <= N {
		return true // 该组牌被迫全出,无取舍
	}

	// m > N:组内有取舍,按结构跟牌
	if lead.Type == "single" {
		return true // 任意一张
	}

	if lead.Type == "pair" {
		if PairCount(handG) >= 1 {
			return isPairCards(playG) // 有对必须跟对(任意对)
		}
		if G == "TRUMP" {
			return topSingletonsOK(playG, handG, 2, trumpSuit) // 主牌跟大
		}
		return true // 边牌:任意两张单
	}

	// tractor
	k := N / 2
	required := k
	if pc := PairCount(handG); pc < required {
		required = pc
	}
	if PairCount(playG) != required {
		return false // 必须用满最大对子数
	}
	if MaxTractorLen(handG, trumpSuit) >= k && MaxTractorLen(playG, trumpSuit) < k {
		return false // 有(够长)拖拉机必须跟拖拉机
	}
	singlesNeeded := N - 2*required
	if singlesNeeded > 0 && G == "TRUMP" {
		return topSingletonsOK(playG, handG, singlesNeeded, trumpSuit) // 单牌部分跟大
	}
	return true
}
