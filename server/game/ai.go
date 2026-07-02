// ai.go — 电脑玩家(记牌 + 抢分/封锁 + 喂分/躲分),移植自 src/ai.js
package game

import (
	"math"
	"sort"
)

func ascS(cards []Card, t string) []Card {
	a := append([]Card(nil), cards...)
	sort.SliceStable(a, func(i, j int) bool { return Strength(a[i], t) < Strength(a[j], t) })
	return a
}
func descS(cards []Card, t string) []Card {
	a := append([]Card(nil), cards...)
	sort.SliceStable(a, func(i, j int) bool { return Strength(a[i], t) > Strength(a[j], t) })
	return a
}
func sideOf(hand []Card, t string) []Card {
	var out []Card
	for _, c := range hand {
		if CardGroup(c, t) != "TRUMP" {
			out = append(out, c)
		}
	}
	return out
}
func trumpOf(hand []Card, t string) []Card {
	var out []Card
	for _, c := range hand {
		if CardGroup(c, t) == "TRUMP" {
			out = append(out, c)
		}
	}
	return out
}

// 按 (花色,点数) 分组,保持出现顺序(与 JS Map 一致)
func groupByKeyOrdered(cardsG []Card) [][]Card {
	idx := map[string]int{}
	var out [][]Card
	for _, c := range cardsG {
		k := cardKey(c)
		if i, ok := idx[k]; ok {
			out[i] = append(out[i], c)
		} else {
			idx[k] = len(out)
			out = append(out, []Card{c})
		}
	}
	return out
}
func pairList(cardsG []Card) [][]Card {
	var out [][]Card
	for _, a := range groupByKeyOrdered(cardsG) {
		if len(a) >= 2 {
			out = append(out, a[:2])
		}
	}
	return out
}
func singleList(cardsG []Card) []Card {
	var out []Card
	for _, a := range groupByKeyOrdered(cardsG) {
		if len(a) == 1 {
			out = append(out, a[0])
		}
	}
	return out
}

// 在对子列表里找一条长度 k、且最大那对 strength > minTop 的拖拉机(按自然阶梯,同 lane)。
// 取满足条件里"最小"(top 最低)的一条;找不到返回 nil。与 combos/follow 的相邻判定一致。
func findLadderRun(pairs [][]Card, k int, t string, minTop int) [][]Card {
	type entry struct {
		p   []Card
		pos int
		alt int
		s   int
	}
	laneOrder := []string{}
	byLane := map[string][]entry{}
	for _, p := range pairs {
		r := TractorRankOf(p[0], t)
		if _, ok := byLane[r.Lane]; !ok {
			laneOrder = append(laneOrder, r.Lane)
		}
		byLane[r.Lane] = append(byLane[r.Lane], entry{p: p, pos: r.Pos, alt: r.Alt, s: Strength(p[0], t)})
	}
	var found [][]Card
	foundTop := math.MaxInt
	for _, lane := range laneOrder {
		list := byLane[lane]
		// 主 A 有两个可选阶梯位(同 lane 最多一对 A)→ 分别试 pos 与 alt
		var flex *entry
		var fixed []entry
		for i := range list {
			if list[i].alt != 0 && flex == nil {
				flex = &list[i]
			} else {
				fixed = append(fixed, list[i])
			}
		}
		var variants [][]entry
		if flex != nil {
			v1 := append(append([]entry(nil), fixed...), *flex)
			altE := *flex
			altE.pos = altE.alt
			v2 := append(append([]entry(nil), fixed...), altE)
			variants = [][]entry{v1, v2}
		} else {
			variants = [][]entry{fixed}
		}
		for _, variant := range variants {
			arr := append([]entry(nil), variant...)
			sort.SliceStable(arr, func(i, j int) bool { return arr[i].pos < arr[j].pos })
			for i := 0; i+k <= len(arr); i++ {
				ok := true
				for j := 1; j < k; j++ {
					if arr[i+j].pos-arr[i+j-1].pos != 1 {
						ok = false
						break
					}
				}
				if !ok {
					continue
				}
				top := 0
				for _, x := range arr[i : i+k] {
					if x.s > top {
						top = x.s
					}
				}
				if top <= minTop {
					continue
				}
				if found == nil || top < foundTop {
					run := make([][]Card, k)
					for j, x := range arr[i : i+k] {
						run[j] = x.p
					}
					found, foundTop = run, top
				}
			}
		}
	}
	return found
}

// 已经亮出的所有牌(用于记牌)
func seenCards(g *Game) []Card {
	var out []Card
	for _, tr := range g.Tricks {
		for _, p := range tr.Plays {
			out = append(out, p.Cards...)
		}
	}
	for _, p := range g.TrickPlays {
		out = append(out, p.Cards...)
	}
	return out
}

// 同(边)花色里比 card 更大、且还没出现(未亮出、不在我手)的张数 —— 0 即为该花色当前最大(boss)
func unseenHigher(card Card, seen, hand []Card, t string) int {
	if CardGroup(card, t) == "TRUMP" {
		return 99
	}
	suit, s := card.Suit, Strength(card, t)
	cnt := 0
	for rank := 4; rank <= 14; rank++ {
		if rank == 2 || rank == 3 {
			continue
		}
		if Strength(Card{Suit: suit, Rank: rank}, t) <= s {
			continue
		}
		copies := 2
		for _, c := range seen {
			if c.Suit == suit && c.Rank == rank {
				copies--
			}
		}
		for _, c := range hand {
			if c.Suit == suit && c.Rank == rank {
				copies--
			}
		}
		if copies > 0 {
			cnt += copies
		}
	}
	return cnt
}

// ---- 喊分(逐级 +10,直到超出自己的目标)----

// JS Math.round:恰好 .5 时向 +∞ 取整(与 Go math.Round 的"远离零"不同)
func jsRound(x float64) int { return int(math.Floor(x + 0.5)) }

func bidTarget(hand []Card) int {
	jok, threes, twos := 0, 0, 0
	sc := map[string]int{"S": 0, "H": 0, "D": 0, "C": 0}
	for _, c := range hand {
		if c.Suit == "JOKER" {
			jok++
		} else {
			if c.Rank == 3 {
				threes++
			} else if c.Rank == 2 {
				twos++
			}
			sc[c.Suit]++
		}
	}
	best := 0
	for _, s := range Suits {
		if sc[s] > best {
			best = sc[s]
		}
	}
	str := float64(jok)*1.5 + float64(threes)*1.2 + float64(twos)*1.0 + float64(best)*0.4
	// 烂牌返回 <100(弃喊),只有够强的手牌才往上喊;上限 200
	v := 100 + 10*jsRound(str-13)
	if v > 200 {
		return 200
	}
	return v
}

// AiBid 返回喊分数;0 = 不喊
func AiBid(g *Game, seat int) int {
	lv := g.NextBidLevel()
	if bidTarget(g.Hands[seat]) >= lv {
		return lv // 愿意就加最小一档,否则放弃
	}
	return 0
}

// AiTrump 亮主:选最长花色当主
func AiTrump(g *Game, seat int) string {
	sc := map[string]int{"S": 0, "H": 0, "D": 0, "C": 0}
	for _, c := range g.Hands[seat] {
		if c.Suit != "JOKER" {
			sc[c.Suit]++
		}
	}
	best := "S"
	for _, s := range Suits {
		if sc[s] > sc[best] {
			best = s
		}
	}
	return best
}

// ---- 扣底:扣最没用的(非主、非分、低点)----

func discardScore(c Card, t string) int {
	s := 0
	if IsTrump(c, t) {
		s += 1000
	}
	if PointValue(c) > 0 {
		s += 500
	}
	if CardGroup(c, t) != "TRUMP" {
		s += c.Rank
	}
	return s
}

func AiBury(g *Game, seat int) []Card {
	t, hand, need := g.TrumpSuit, g.Hands[seat], g.KittySize
	var discards []Card
	// 1) 优先把"短的、无分的边花色"整门扣掉做空门 → 以后那门一出就能用主牌杀
	bySuit := map[string][]Card{}
	for _, c := range hand {
		if CardGroup(c, t) != "TRUMP" {
			bySuit[c.Suit] = append(bySuit[c.Suit], c)
		}
	}
	var suits []string
	for _, s := range Suits {
		if len(bySuit[s]) > 0 {
			suits = append(suits, s)
		}
	}
	sort.SliceStable(suits, func(i, j int) bool { return len(bySuit[suits[i]]) < len(bySuit[suits[j]]) })
	for _, s := range suits {
		grp := bySuit[s]
		hasPoint := false
		for _, c := range grp {
			if PointValue(c) > 0 {
				hasPoint = true
				break
			}
		}
		if len(grp) <= need-len(discards) && !hasPoint {
			discards = append(discards, grp...)
		}
	}
	// 2) 剩余名额:扣最没用的(非主、非分、低点)
	if len(discards) < need {
		ids := map[string]bool{}
		for _, c := range discards {
			ids[c.ID] = true
		}
		var rest []Card
		for _, c := range hand {
			if !ids[c.ID] {
				rest = append(rest, c)
			}
		}
		sort.SliceStable(rest, func(i, j int) bool { return discardScore(rest[i], t) < discardScore(rest[j], t) })
		for _, c := range rest {
			if len(discards) >= need {
				break
			}
			discards = append(discards, c)
		}
	}
	if len(discards) > need {
		discards = discards[:need]
	}
	return discards
}

// AiLead 首攻
func AiLead(g *Game, seat int) []Card {
	t, hand := g.TrumpSuit, g.Hands[seat]
	isZhuang := seat == g.Declarer
	side, trumps := sideOf(hand, t), trumpOf(hand, t)
	if isZhuang && len(trumps) >= 5 {
		return []Card{descS(trumps, t)[0]} // 庄家拉主
	}
	seen := seenCards(g)
	var bosses []Card
	for _, c := range side {
		if unseenHigher(c, seen, hand, t) == 0 {
			bosses = append(bosses, c)
		}
	}
	if len(bosses) > 0 {
		return []Card{descS(bosses, t)[0]} // 兑现 boss:稳赢一墩
	}
	if len(side) > 0 {
		return []Card{ascS(side, t)[0]} // 无 boss → 出小牌,别白送大牌
	}
	return []Card{ascS(hand, t)[0]}
}

// BuildFollow 构造一手合法"垫牌"(默认丢最小)
func BuildFollow(hand []Card, lead *Combo, t string) []Card {
	N, G := lead.Length, lead.Group
	var handG, other []Card
	for _, c := range hand {
		if CardGroup(c, t) == G {
			handG = append(handG, c)
		} else {
			other = append(other, c)
		}
	}
	m := len(handG)
	if m <= N {
		return append(append([]Card(nil), handG...), ascS(other, t)[:N-m]...)
	}
	if lead.Type == "single" {
		return []Card{ascS(handG, t)[0]}
	}
	if lead.Type == "pair" {
		pairs := pairList(handG)
		if len(pairs) > 0 {
			sort.SliceStable(pairs, func(i, j int) bool { return Strength(pairs[i][0], t) < Strength(pairs[j][0], t) })
			return pairs[0]
		}
		singles := singleList(handG)
		if G == "TRUMP" {
			return descS(singles, t)[:2]
		}
		return ascS(singles, t)[:2]
	}
	// tractor
	k := N / 2
	pairs := pairList(handG)
	required := k
	if len(pairs) < required {
		required = len(pairs)
	}
	var chosen [][]Card
	if MaxTractorLen(handG, t) >= k {
		chosen = findLadderRun(pairs, k, t, math.MinInt)
	}
	if chosen == nil {
		lp := append([][]Card(nil), pairs...)
		sort.SliceStable(lp, func(i, j int) bool { return Strength(lp[i][0], t) < Strength(lp[j][0], t) })
		chosen = lp[:required]
	}
	var cards []Card
	for _, p := range chosen {
		cards = append(cards, p...)
	}
	if need := N - len(cards); need > 0 {
		singles := singleList(handG)
		if G == "TRUMP" {
			cards = append(cards, descS(singles, t)[:need]...)
		} else {
			cards = append(cards, ascS(singles, t)[:need]...)
		}
	}
	return cards
}

// 丢牌排序键:feed=喂分(先丢大分牌,其余丢小);否则躲分(先丢小杂牌,分牌最后)
func dumpKey(c Card, t string, feed bool) int {
	pv := PointValue(c)
	if feed {
		if pv > 0 {
			return -1000 - pv*10
		}
		return Strength(c, t)
	}
	if pv > 0 {
		return 10000 + pv
	}
	return Strength(c, t)
}
func dumpOrder(cards []Card, t string, feed bool) []Card {
	a := append([]Card(nil), cards...)
	sort.SliceStable(a, func(i, j int) bool { return dumpKey(a[i], t, feed) < dumpKey(a[j], t, feed) })
	return a
}

// 不抢时的智能垫牌:队友赢就喂分,对手赢就躲分
func chooseDump(hand []Card, lead *Combo, t string, feed bool) []Card {
	N, G := lead.Length, lead.Group
	var handG, other []Card
	for _, c := range hand {
		if CardGroup(c, t) == G {
			handG = append(handG, c)
		} else {
			other = append(other, c)
		}
	}
	m := len(handG)
	if m <= N {
		return append(append([]Card(nil), handG...), dumpOrder(other, t, feed)[:N-m]...)
	}
	if lead.Type == "single" {
		return []Card{dumpOrder(handG, t, feed)[0]}
	}
	if lead.Type == "pair" {
		pairs := pairList(handG)
		if len(pairs) > 0 {
			sort.SliceStable(pairs, func(i, j int) bool {
				return dumpKey(pairs[i][0], t, feed) < dumpKey(pairs[j][0], t, feed)
			})
			return pairs[0]
		}
		singles := singleList(handG)
		if G == "TRUMP" {
			return descS(singles, t)[:2]
		}
		return dumpOrder(singles, t, feed)[:2]
	}
	return BuildFollow(hand, lead, t) // 拖拉机较少见,退回最小垫
}

// 在 cardsG 里找压过 minTop 的、同型同长的最小组合;没有返回 nil
func findBeatingInGroup(cardsG []Card, lead *Combo, minTop int, t string) []Card {
	if lead.Type == "single" {
		var cand []Card
		for _, c := range cardsG {
			if Strength(c, t) > minTop {
				cand = append(cand, c)
			}
		}
		if len(cand) == 0 {
			return nil
		}
		return []Card{ascS(cand, t)[0]}
	}
	if lead.Type == "pair" {
		var cand [][]Card
		for _, p := range pairList(cardsG) {
			if Strength(p[0], t) > minTop {
				cand = append(cand, p)
			}
		}
		if len(cand) == 0 {
			return nil
		}
		sort.SliceStable(cand, func(i, j int) bool { return Strength(cand[i][0], t) < Strength(cand[j][0], t) })
		return cand[0]
	}
	k := lead.Length / 2
	run := findLadderRun(pairList(cardsG), k, t, minTop)
	if run == nil {
		return nil
	}
	var out []Card
	for _, p := range run {
		out = append(out, p...)
	}
	return out
}

// BuildWinningFollow 构造能吃住当前最大(best)的跟牌;做不到返回 nil
func BuildWinningFollow(hand []Card, lead, best *Combo, t string) []Card {
	G := lead.Group
	var handG []Card
	for _, c := range hand {
		if CardGroup(c, t) == G {
			handG = append(handG, c)
		}
	}
	trumps := trumpOf(hand, t)
	if len(handG) > 0 {
		if best.Group != G {
			return nil
		}
		if len(handG) < lead.Length {
			return nil
		}
		return findBeatingInGroup(handG, lead, best.Top, t)
	}
	if G != "TRUMP" {
		if len(trumps) < lead.Length {
			return nil
		}
		minTop := -1
		if best.Group == "TRUMP" {
			minTop = best.Top
		}
		return findBeatingInGroup(trumps, lead, minTop, t)
	}
	return nil
}

// AiFollow 跟牌决策
func AiFollow(g *Game, seat int) []Card {
	t, lead, hand := g.TrumpSuit, g.LeadCombo, g.Hands[seat]
	isZhuang := seat == g.Declarer

	best, bi := g.TrickPlays[0].Combo, 0
	for i := 1; i < len(g.TrickPlays); i++ {
		if Beats(g.TrickPlays[i].Combo, best) {
			best, bi = g.TrickPlays[i].Combo, i
		}
	}
	winnerIsZhuang := g.TrickPlays[bi].Seat == g.Declarer
	points := 0
	for _, p := range g.TrickPlays {
		for _, c := range p.Cards {
			points += PointValue(c)
		}
	}
	isLast := len(g.TrickPlays) == g.Players-1

	win := BuildWinningFollow(hand, lead, best, t)
	wantWin := false
	if win != nil {
		if isZhuang {
			wantWin = !winnerIsZhuang && (points > 0 || isLast) // 庄家:封锁闲家的分墩
		} else {
			wantWin = winnerIsZhuang && (points > 0 || isLast) // 闲家:只抢庄家的墩,不抢队友
		}
	}
	if wantWin && IsLegalFollow(hand, lead, win, t) {
		return win
	}

	// 不抢 → 智能垫牌:队友(闲家)赢、且庄家已出牌(吃不动了)才喂分;否则躲分
	zhuangPlayed := false
	for _, p := range g.TrickPlays {
		if p.Seat == g.Declarer {
			zhuangPlayed = true
			break
		}
	}
	feed := !isZhuang && !winnerIsZhuang && zhuangPlayed
	play := chooseDump(hand, lead, t, feed)
	if IsLegalFollow(hand, lead, play, t) {
		return play
	}
	return BuildFollow(hand, lead, t)
}
