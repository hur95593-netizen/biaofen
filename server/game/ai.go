// ai.go — 电脑玩家(记牌 + 抢分/封锁 + 喂分/躲分),移植自 src/ai.js
package game

import (
	"math"
	"sort"
)

// ---- 策略实验开关(ab_test.go 用来做新旧对战;正式行为 = 全 true)----
var (
	aiV4Zhuang = true // 庄家:对子/拖拉机拉主(榨「跟大」)+ 对手断主即停
	aiV4Xian   = true // 闲家:借队友断门甩分牌 + 队友 boss 提前喂分
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

// 一个组(边花色或主)的全部候选牌(每种 2 张)
func groupCandidates(group, t string) []Card {
	if group != "TRUMP" {
		out := make([]Card, 0, 11)
		for r := 4; r <= 14; r++ {
			out = append(out, Card{Suit: group, Rank: r})
		}
		return out
	}
	out := []Card{{Suit: "JOKER", Rank: BigJoker}, {Suit: "JOKER", Rank: SmallJoker}}
	for _, s := range Suits {
		out = append(out, Card{Suit: s, Rank: 3}, Card{Suit: s, Rank: 2})
	}
	for r := 4; r <= 14; r++ {
		out = append(out, Card{Suit: t, Rank: r})
	}
	return out
}

// cand 还没露面(不在已出牌、不在我手)的张数
func remainingCopies(cand Card, seen, hand []Card) int {
	copies := 2
	for _, x := range seen {
		if x.Suit == cand.Suit && x.Rank == cand.Rank {
			copies--
		}
	}
	for _, x := range hand {
		if x.Suit == cand.Suit && x.Rank == cand.Rank {
			copies--
		}
	}
	if copies < 0 {
		copies = 0
	}
	return copies
}

// 组内(边花色与主牌通用)比 card 更大、还没露面的张数 —— 0 即当前最大(boss)
func unseenHigher(card Card, seen, hand []Card, t string) int {
	s := Strength(card, t)
	cnt := 0
	for _, cand := range groupCandidates(CardGroup(card, t), t) {
		if Strength(cand, t) <= s {
			continue
		}
		cnt += remainingCopies(cand, seen, hand)
	}
	return cnt
}

// 组内比 card 更大、且对手还可能凑成一对的档位数 —— 0 即我的对子无对可压(不含主杀)
func unseenHigherPair(card Card, seen, hand []Card, t string) int {
	s := Strength(card, t)
	cnt := 0
	for _, cand := range groupCandidates(CardGroup(card, t), t) {
		if Strength(cand, t) <= s {
			continue
		}
		if remainingCopies(cand, seen, hand) == 2 {
			cnt++
		}
	}
	return cnt
}

// 从打过的墩推断:谁在哪个组已经断门(没跟上首攻组)
func voidGroups(g *Game) map[int]map[string]bool {
	out := map[int]map[string]bool{}
	mark := func(seat int, group string) {
		if out[seat] == nil {
			out[seat] = map[string]bool{}
		}
		out[seat][group] = true
	}
	scan := func(plays []Play) {
		if len(plays) == 0 || plays[0].Combo == nil {
			return
		}
		lead := plays[0].Combo.Group
		for _, p := range plays[1:] {
			for _, c := range p.Cards {
				if CardGroup(c, g.TrumpSuit) != lead {
					mark(p.Seat, lead)
					break
				}
			}
		}
	}
	for _, tr := range g.Tricks {
		scan(tr.Plays)
	}
	scan(g.TrickPlays)
	return out
}

// 我在该边花色的赢牌会不会被对头用主砸掉:对头断了这门、且没断主、场上还有主
func ruffRisk(g *Game, seat int, group string) bool {
	if group == "TRUMP" {
		return false
	}
	if othersTrumps(g, seat) <= 0 {
		return false
	}
	voids := voidGroups(g)
	for o := 0; o < g.Players; o++ {
		if o == seat {
			continue
		}
		if (seat == g.Declarer) == (o == g.Declarer) {
			continue // 只怕对头,不怕队友
		}
		if voids[o][group] && !voids[o]["TRUMP"] {
			return true
		}
	}
	return false
}

// 对手手里(约)还剩多少主。底牌里的主看不见 → 宁可高估,多拉一轮
func othersTrumps(g *Game, seat int) int {
	t := g.TrumpSuit
	total := 42 // 4王 + 8张3 + 8张2 + 主花色4..A共22张
	for _, c := range seenCards(g) {
		if IsTrump(c, t) {
			total--
		}
	}
	for _, c := range g.Hands[seat] {
		if IsTrump(c, t) {
			total--
		}
	}
	return total
}

// ---- 喊分(逐级 +10,直到超出自己的目标)----

// JS Math.round:恰好 .5 时向 +∞ 取整(与 Go math.Round 的"远离零"不同)
func jsRound(x float64) int { return int(math.Floor(x + 0.5)) }

// bidTarget 以"坐庄实力"评估手牌 → 我最多敢喊到多少
// 考量:王/常主(硬控制)、最长花色(主的长度)、对子(结构)、短门(可扣底做空门去杀)
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
	bestSuit, best := "S", 0
	for _, s := range Suits {
		if sc[s] > best {
			bestSuit, best = s, sc[s]
		}
	}
	shorts := 0 // 亮主后可扣底清空的短门(≤1 张)→ 空门用主杀,是坐庄的大优势
	for _, s := range Suits {
		if s != bestSuit && sc[s] <= 1 {
			shorts++
		}
	}
	str := float64(jok)*1.6 + float64(threes)*1.3 + float64(twos)*1.0 +
		float64(best)*0.5 + float64(PairCount(hand))*0.3 + float64(shorts)*0.8
	// 烂牌返回 <100(弃喊);实力越强目标越高,上限 200
	v := 100 + 10*jsRound(str-15)
	if v > 200 {
		return 200
	}
	return v
}

// AiBid 返回喊分数;0 = 不喊。实力大幅超过当前价 → 跳喊施压,吓退还想跟的人
func AiBid(g *Game, seat int) int {
	lv := g.NextBidLevel()
	target := bidTarget(g.Hands[seat])
	if target < lv {
		return 0
	}
	if target >= lv+30 {
		bid := lv + 20 // 跳两档:抬高对方跟价成本
		if bid > 200 {
			bid = 200
		}
		return bid
	}
	return lv
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
	switch c.Rank {
	case 13:
		s += 800 // K:分牌 + 大牌,尽量留着打
	case 14:
		s += 500 // A:boss,别扣
	case 10:
		s -= 10 // 10/5:打不赢就藏进底牌护分(闲家抢不到)
	case 5:
		s -= 40
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
		hasBig := false
		for _, c := range grp {
			if c.Rank >= 13 { // A/K 留着打;5/10 随短门扣掉反而是藏分
				hasBig = true
				break
			}
		}
		if len(grp) <= need-len(discards) && !hasBig {
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

// AiLead 首攻:拖拉机 > 庄家控主 > boss 对子 > boss 单张 > 小牌过渡
// boss 兑现会避开"对头已断门、可能用主砸"的花色;拖拉机结构免疫(压它需要同长主拖拉机)不用避
func AiLead(g *Game, seat int) []Card {
	t, hand := g.TrumpSuit, g.Hands[seat]
	seen := seenCards(g)
	risky := func(group string) bool { return ruffRisk(g, seat, group) }
	if run := leadTractor(hand, t, seen); run != nil {
		return run // 拖拉机几乎无解,还能一手甩掉多张
	}
	if seat == g.Declarer {
		if draw := leadDrawTrump(g, seat, seen); draw != nil {
			return draw
		}
	}
	if p := leadBossPair(hand, t, seen, risky); p != nil {
		return p // 对子按对子打:清对手的对子和大牌
	}
	if throw := leadThrow(g, seat, seen); throw != nil {
		return throw // 结构牌打完,才轮到甩落单的必大主
	}
	if c := leadBossSingle(hand, t, seen, risky); c != nil {
		return c
	}
	if pr := leadPartnerRuff(g, seat, seen); pr != nil {
		return pr // 借刀杀人:甩分牌给队友的断门
	}
	return smallLead(hand, t)
}

// 甩牌:只甩"落单"的必大主 —— 绝不拆对子(对子/拖拉机留着按结构清对手的大牌)。
// ≥2 张一把甩;恰 1 张按普通单张兑现。
func leadThrow(g *Game, seat int, seen []Card) []Card {
	t := g.TrumpSuit
	hand := g.Hands[seat]
	var dominant []Card
	for _, e := range orderedByKey(trumpOf(hand, t)) {
		if e.count != 1 {
			continue // 成对的主不参与甩牌
		}
		if unseenHigher(e.card, seen, hand, t) == 0 {
			dominant = append(dominant, e.card)
		}
	}
	if len(dominant) == 0 {
		return nil
	}
	return dominant
}

// 值得首攻的拖拉机:3 对及以上直接出;2 对要求顶张已无更高对(boss)
func leadTractor(hand []Card, t string, seen []Card) []Card {
	pairs := pairList(hand)
	if len(pairs) < 2 {
		return nil
	}
	for k := len(pairs); k >= 3; k-- {
		if run := findLadderRun(pairs, k, t, math.MinInt); run != nil {
			return flattenPairs(run)
		}
	}
	minTop := math.MinInt
	for {
		run := findLadderRun(pairs, 2, t, minTop)
		if run == nil {
			return nil
		}
		top := runTopCard(run, t)
		if unseenHigherPair(top, seen, hand, t) == 0 {
			return flattenPairs(run)
		}
		minTop = Strength(top, t) // 这条顶张不硬,往更高的找
	}
}

func flattenPairs(run [][]Card) []Card {
	var out []Card
	for _, p := range run {
		out = append(out, p...)
	}
	return out
}

func runTopCard(run [][]Card, t string) Card {
	top := run[0][0]
	for _, p := range run {
		if Strength(p[0], t) > Strength(top, t) {
			top = p[0]
		}
	}
	return top
}

// 庄家控主。v4 核心:利用「跟大」规则 —— 跟主对子/拖拉机时没结构的人被迫交出
// 最大的单主(含大王!),所以拉主优先出 拖拉机 > 对子(哪怕小对)> boss 单张;
// 绝不再用小单主送墩(v3 的毛病:白丢一墩还被垫分)。
func leadDrawTrump(g *Game, seat int, seen []Card) []Card {
	t := g.TrumpSuit
	hand := g.Hands[seat]
	trumps := trumpOf(hand, t)
	if len(trumps) == 0 {
		return nil
	}
	if !aiV4Zhuang {
		// v3 行为(A/B 基线):boss 边赢边拉;主长无 boss 用小主换大主
		if othersTrumps(g, seat) < 3 {
			return nil
		}
		top := descS(trumps, t)[0]
		if unseenHigher(top, seen, hand, t) == 0 {
			return []Card{top}
		}
		if len(trumps) >= 6 {
			for _, c := range ascS(trumps, t) {
				if PointValue(c) == 0 {
					return []Card{c}
				}
			}
		}
		return nil
	}
	if enemiesAllTrumpVoid(g, seat) || othersTrumps(g, seat) < 3 {
		return nil // 对手主已尽,立刻停手转攻
	}
	pairs := pairList(trumps)
	// 1) boss 主对:必赢 + 跟大逼对手交出最大的单主(大王也逃不掉),一墩拉走 6 张
	var bossPair []Card
	for _, p := range pairs {
		if unseenHigherPair(p[0], seen, hand, t) > 0 {
			continue
		}
		if bossPair == nil || Strength(p[0], t) < Strength(bossPair[0], t) {
			bossPair = p // 最小的 boss 对就够赢,大的留后手
		}
	}
	if bossPair != nil {
		return bossPair
	}
	// 2) boss 单张:必赢,拉走 3 张
	top := descS(trumps, t)[0]
	if unseenHigher(top, seen, hand, t) == 0 {
		return []Card{top}
	}
	// 3) 无必赢结构但主够长:便宜快拉(A/B 实测:3 人局快速消耗对手的主 > 保守惜牌)。
	//    优先小对(一墩换对手 4 张),没有对再用小单
	if len(trumps) >= 6 {
		var lowPair []Card
		for _, p := range pairs {
			if PointValue(p[0]) > 0 {
				continue
			}
			if lowPair == nil || Strength(p[0], t) < Strength(lowPair[0], t) {
				lowPair = p
			}
		}
		if lowPair != nil {
			return lowPair
		}
		for _, c := range ascS(trumps, t) {
			if PointValue(c) == 0 {
				return []Card{c}
			}
		}
	}
	return nil
}

// 所有对头都已亮出断主(跟主牌时垫过别的)→ 主拉干净了
func enemiesAllTrumpVoid(g *Game, seat int) bool {
	voids := voidGroups(g)
	for o := 0; o < g.Players; o++ {
		if o == seat {
			continue
		}
		if (seat == g.Declarer) == (o == g.Declarer) {
			continue
		}
		if !voids[o]["TRUMP"] {
			return false
		}
	}
	return true
}

// 借刀杀人(闲家、且庄家紧跟我后手时):队友断了某边门且还可能有主、庄家没断这门 →
// 故意甩一张分牌过去:庄被迫跟牌,队友最后用主杀,分数全归闲家。
func leadPartnerRuff(g *Game, seat int, seen []Card) []Card {
	if !aiV4Xian || seat == g.Declarer {
		return nil
	}
	if (seat+1)%g.Players != g.Declarer {
		return nil // 需要出牌顺序 = 我 → 庄 → 队友(队友最后落牌才能稳杀)
	}
	t := g.TrumpSuit
	hand := g.Hands[seat]
	voids := voidGroups(g)
	var best Card
	bestScore := 0
	for _, c := range hand {
		grp := CardGroup(c, t)
		if grp == "TRUMP" || PointValue(c) == 0 {
			continue
		}
		partnerCanRuff := false
		for o := 0; o < g.Players; o++ {
			if o == seat || o == g.Declarer {
				continue
			}
			if voids[o][grp] && !voids[o]["TRUMP"] {
				partnerCanRuff = true
			}
		}
		if !partnerCanRuff || voids[g.Declarer][grp] {
			continue // 队友杀不了,或庄自己也断门(会反杀)
		}
		if score := PointValue(c)*10 + c.Rank; score > bestScore {
			best, bestScore = c, score
		}
	}
	if bestScore == 0 {
		return nil
	}
	return []Card{best}
}

// 已无更高对的对子 → 兑现;优先带分的(闲家一手捡 20);避开会被主对砸的花色
func leadBossPair(hand []Card, t string, seen []Card, risky func(string) bool) []Card {
	var best []Card
	bestScore := math.MinInt
	for _, p := range pairList(hand) {
		c := p[0]
		if unseenHigherPair(c, seen, hand, t) > 0 {
			continue
		}
		if g := CardGroup(c, t); g != "TRUMP" && risky(g) {
			continue
		}
		score := PointValue(c)*20 + Strength(c, t)
		if score > bestScore {
			best, bestScore = p, score
		}
	}
	return best
}

// 边花色里"当前最大"的落单牌 → 兑现,优先带分的;不拆对子;避开会被砸的花色
func leadBossSingle(hand []Card, t string, seen []Card, risky func(string) bool) []Card {
	var best Card
	bestScore := math.MinInt
	for _, e := range orderedByKey(hand) {
		if e.count != 1 {
			continue
		}
		c := e.card
		if CardGroup(c, t) == "TRUMP" {
			continue // 主 boss 由庄家控主逻辑处理;闲家拉主反帮庄
		}
		if unseenHigher(c, seen, hand, t) > 0 || risky(c.Suit) {
			continue
		}
		score := PointValue(c)*20 + Strength(c, t)
		if score > bestScore {
			best, bestScore = c, score
		}
	}
	if bestScore == math.MinInt {
		return nil
	}
	return []Card{best}
}

// 过渡:最小的不带分边单张 → 最小不带分边牌 → 最小边牌 → 最小不带分牌 → 最小牌
func smallLead(hand []Card, t string) []Card {
	side := sideOf(hand, t)
	if len(side) > 0 {
		var pool []Card
		for _, c := range singleList(side) {
			if PointValue(c) == 0 {
				pool = append(pool, c)
			}
		}
		if len(pool) > 0 {
			return []Card{ascS(pool, t)[0]}
		}
		for _, c := range side {
			if PointValue(c) == 0 {
				pool = append(pool, c)
			}
		}
		if len(pool) > 0 {
			return []Card{ascS(pool, t)[0]}
		}
		return []Card{ascS(side, t)[0]}
	}
	var pool []Card
	for _, c := range hand {
		if PointValue(c) == 0 {
			pool = append(pool, c)
		}
	}
	if len(pool) > 0 {
		return []Card{ascS(pool, t)[0]}
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
	if lead.Type == "throw" {
		return ascS(handG, t)[:N] // 甩牌:垫最小的 N 张
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
	if lead.Type == "throw" {
		return dumpOrder(handG, t, feed)[:N] // 甩牌:按喂/躲原则垫满 N 张
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

// 当前最大的一手是否为「队友打出的边花色必大牌」且庄家大概率只能跟着垫:
// 顶张组内当前最大 + 庄没亮过这门断门 + 庄曾跟过这门(证实有牌)→ 这墩基本归队友
func teammateBossSecured(g *Game, bi int, myHand []Card) bool {
	best := g.TrickPlays[bi]
	if best.Combo == nil || best.Combo.Group == "TRUMP" {
		return false
	}
	t := g.TrumpSuit
	top := best.Cards[0]
	for _, c := range best.Cards {
		if Strength(c, t) > Strength(top, t) {
			top = c
		}
	}
	if unseenHigher(top, seenCards(g), myHand, t) > 0 {
		return false
	}
	voids := voidGroups(g)
	if voids[g.Declarer][best.Combo.Group] {
		return false // 庄断门 → 可能用主杀,别喂
	}
	return provenFollows(g, g.Declarer, best.Combo.Group)
}

// seat 是否曾整手跟上过该组(证实他有这门牌)
func provenFollows(g *Game, seat int, group string) bool {
	for _, tr := range g.Tricks {
		if len(tr.Plays) == 0 || tr.Plays[0].Combo == nil || tr.Plays[0].Combo.Group != group {
			continue
		}
		for _, p := range tr.Plays {
			if p.Seat != seat {
				continue
			}
			all := true
			for _, c := range p.Cards {
				if CardGroup(c, g.TrumpSuit) != group {
					all = false
					break
				}
			}
			if all {
				return true
			}
		}
	}
	return false
}

// 在 cardsG 里找压过 minTop 的、同型同长的最小组合;没有返回 nil
func findBeatingInGroup(cardsG []Card, lead *Combo, minTop int, t string) []Card {
	if lead.Type == "throw" {
		return nil // 甩牌是"必大"集合,压不了
	}
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
		// 白捡节奏:对头正赢着,而我能用"反正当前最大"的同组单张吃 → 无分也抢(赢下一手首攻权)
		if !wantWin && lead.Type == "single" && len(win) == 1 {
			enemyWinning := winnerIsZhuang != isZhuang
			if enemyWinning && CardGroup(win[0], t) == lead.Group &&
				unseenHigher(win[0], seenCards(g), hand, t) == 0 {
				wantWin = true
			}
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
	// v4 闲家:队友领着「边花色必大牌」、庄被证实还有这门(跟过且没断)→ 不等庄出牌就喂分
	if aiV4Xian && !feed && !isZhuang && !winnerIsZhuang && !zhuangPlayed {
		feed = teammateBossSecured(g, bi, hand)
	}
	play := chooseDump(hand, lead, t, feed)
	if IsLegalFollow(hand, lead, play, t) {
		return play
	}
	return BuildFollow(hand, lead, t)
}
