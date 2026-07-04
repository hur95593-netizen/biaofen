// game.go — 「飙分」一桌/一局流程状态机(移植自 src/game.js)
// 阶段 Phase: bidding → declare → kitty → play → done
package game

import (
	"errors"
	"math/rand"
	"strconv"
)

// PointValue 分数牌:5=5,10=10,K=10
func PointValue(c Card) int {
	if c.Rank == 5 {
		return 5
	}
	if c.Rank == 10 || c.Rank == 13 {
		return 10
	}
	return 0
}

// BaseStake 底分:喊 100 → 100,每多 10 分多 100
func BaseStake(contract int) int { return (contract - 90) * 10 }

func removeCards(hand, cards []Card) []Card {
	ids := map[string]bool{}
	for _, c := range cards {
		ids[c.ID] = true
	}
	out := make([]Card, 0, len(hand))
	for _, c := range hand {
		if !ids[c.ID] {
			out = append(out, c)
		}
	}
	return out
}

type Play struct {
	Seat  int    `json:"seat"`
	Cards []Card `json:"cards"`
	Combo *Combo `json:"combo"`
}

type Trick struct {
	Plays      []Play `json:"plays"`
	WinnerSeat int    `json:"winnerSeat"`
	Points     int    `json:"points"`
}

type Result struct {
	Declarer       int    `json:"declarer"`
	Contract       int    `json:"contract"`
	Line           int    `json:"line"`
	XianPoints     int    `json:"xianPoints"`
	LastTrickBonus int    `json:"lastTrickBonus"`
	Label          string `json:"label"`
	PerXian        int    `json:"perXian"`
	Stake          int    `json:"stake"`
	Deltas         []int  `json:"deltas"`
	Scores         []int  `json:"scores"`
}

// Game 一桌的完整状态。空值约定:Declarer/HighBidder = -1,HighBid/Contract = 0,TrumpSuit = ""。
type Game struct {
	Players int
	Rng     *rand.Rand
	Scores  []int // 累计积分

	FirstBidder int // 起喊人(第一局随机,之后按胜负轮转)
	HandNo      int

	Hands     [][]Card
	Kitty     []Card
	KittySize int
	Buried    []Card

	TrumpSuit  string
	Declarer   int
	Contract   int
	Phase      string
	HighBid    int
	HighBidder int
	Passed     []bool
	BidTurn    int

	XianPoints     int
	XianCaptured   []Card // 闲家捡到的分数牌
	LastTrickBonus int

	Tricks     []Trick
	TrickPlays []Play
	LeadCombo  *Combo
	Leader     int
	Turn       int
	Result     *Result
}

func NewGame(players int, rng *rand.Rand) *Game {
	return &Game{
		Players:     players,
		Rng:         rng,
		Scores:      make([]int, players),
		FirstBidder: rng.Intn(players), // 第一局随机起喊
	}
}

func (g *Game) StartHand() {
	g.HandNo++
	d := Deal(Shuffle(BuildDeck(), g.Rng), g.Players)
	g.Hands = d.Hands
	g.Kitty = d.Kitty
	g.KittySize = d.KittySize
	g.Buried = nil
	g.TrumpSuit = ""
	g.Declarer = -1
	g.Contract = 0
	g.Phase = "bidding"
	g.HighBid = 0
	g.HighBidder = -1
	g.Passed = make([]bool, g.Players)
	g.BidTurn = g.FirstBidder
	g.XianPoints = 0
	g.XianCaptured = nil
	g.LastTrickBonus = 0
	g.Tricks = nil
	g.TrickPlays = nil
	g.LeadCombo = nil
	g.Leader = -1
	g.Turn = -1
	g.Result = nil
}

// ---------- 喊分(多轮拍卖:往上加价,到 200 或其余都放弃才结束)----------

func (g *Game) NextBidLevel() int {
	if g.HighBid == 0 {
		return 100
	}
	if g.HighBid+10 > 200 {
		return 200
	}
	return g.HighBid + 10
}

// PlaceBid amount = 0 表示"不喊"(放弃);否则必须是 100~200、10 的倍数、高于当前最高。
func (g *Game) PlaceBid(seat, amount int) error {
	if g.Phase != "bidding" {
		return errors.New("非喊分阶段")
	}
	if seat != g.BidTurn {
		return errors.New("未轮到该家喊分")
	}
	if amount != 0 {
		floor := 90
		if g.HighBid != 0 {
			floor = g.HighBid
		}
		if amount%10 != 0 || amount < 100 || amount > 200 || amount <= floor {
			return errors.New("喊分必须是 100~200、10 的倍数、且高于当前最高")
		}
		g.HighBid = amount
		g.HighBidder = seat
	} else {
		g.Passed[seat] = true // 放弃后本局不再参与
	}
	if g.HighBid == 200 {
		g.finishBidding() // 到顶,直接坐庄
		return nil
	}
	// 找下一个有资格的人:还没放弃、且不是当前最高者(最高者无须再加价)
	for i := 1; i <= g.Players; i++ {
		c := (seat + i) % g.Players
		if !g.Passed[c] && c != g.HighBidder {
			g.BidTurn = c
			return nil
		}
	}
	g.finishBidding() // 其余都已放弃
	return nil
}

func (g *Game) finishBidding() {
	if g.HighBidder != -1 {
		g.Declarer = g.HighBidder
	} else {
		g.Declarer = g.FirstBidder
	}
	if g.HighBid != 0 {
		g.Contract = g.HighBid
	} else {
		g.Contract = 100
	}
	g.Phase = "declare"
}

// ---------- 亮主 + 扣底 ----------

func (g *Game) DeclareTrump(suit string) error {
	if g.Phase != "declare" {
		return errors.New("非亮主阶段")
	}
	g.TrumpSuit = suit
	g.Hands[g.Declarer] = append(g.Hands[g.Declarer], g.Kitty...) // 庄家拿底牌
	g.Phase = "kitty"
	return nil
}

func (g *Game) BuryCards(cards []Card) error {
	if g.Phase != "kitty" {
		return errors.New("非扣底阶段")
	}
	if len(cards) != g.KittySize {
		return errors.New("扣底数量不对")
	}
	if !isSubMultiset(cards, g.Hands[g.Declarer]) {
		return errors.New("扣底的牌不在手中")
	}
	g.Hands[g.Declarer] = removeCards(g.Hands[g.Declarer], cards)
	g.Buried = append([]Card(nil), cards...)
	g.Phase = "play"
	g.Leader = g.Declarer // 庄家首攻
	g.Turn = g.Declarer
	g.TrickPlays = nil
	g.LeadCombo = nil
	return nil
}

// ---------- 出牌 ----------

func (g *Game) IsLeadTurn() bool { return len(g.TrickPlays) == 0 }

func (g *Game) ValidatePlay(seat int, cards []Card) bool {
	if g.Phase != "play" || seat != g.Turn {
		return false
	}
	if len(cards) == 0 {
		return false
	}
	if !isSubMultiset(cards, g.Hands[seat]) {
		return false
	}
	if g.IsLeadTurn() {
		// 首攻:单/对/拖拉机,或"必大"主牌甩牌
		return DetectCombo(cards, g.TrumpSuit) != nil || g.ValidThrow(seat, cards)
	}
	return IsLegalFollow(g.Hands[seat], g.LeadCombo, cards, g.TrumpSuit)
}

// ValidThrow 甩牌合法性:多张主牌,且未见的主里没有任何一张能大过甩出的最小者(必赢)。
// 底牌里的主也按"未见"算 → 偏保守,但绝不会甩输。
func (g *Game) ValidThrow(seat int, cards []Card) bool {
	if len(cards) < 2 {
		return false
	}
	minS := 1 << 30
	for _, c := range cards {
		if !IsTrump(c, g.TrumpSuit) {
			return false // 只允许甩主牌(副牌不准甩)
		}
		if s := Strength(c, g.TrumpSuit); s < minS {
			minS = s
		}
	}
	seen := seenCards(g)
	for _, cand := range groupCandidates("TRUMP", g.TrumpSuit) {
		if Strength(cand, g.TrumpSuit) > minS && remainingCopies(cand, seen, g.Hands[seat]) > 0 {
			return false
		}
	}
	return true
}

// 甩牌的 Combo(不经 DetectCombo,只在首攻构造;同强度的跟牌压不过它 → 必归首家)
func throwCombo(cards []Card, trumpSuit string) *Combo {
	top := 0
	for _, c := range cards {
		if s := Strength(c, trumpSuit); s > top {
			top = s
		}
	}
	return &Combo{Type: "throw", Length: len(cards), Group: "TRUMP", Top: top}
}

func (g *Game) PlayCards(seat int, cards []Card) error {
	if !g.ValidatePlay(seat, cards) {
		return errors.New("出牌不合法")
	}
	combo := DetectCombo(cards, g.TrumpSuit)
	if g.IsLeadTurn() {
		if combo == nil {
			combo = throwCombo(cards, g.TrumpSuit) // 甩牌
		}
		g.LeadCombo = combo
	}
	g.Hands[seat] = removeCards(g.Hands[seat], cards)
	g.TrickPlays = append(g.TrickPlays, Play{
		Seat:  seat,
		Cards: append([]Card(nil), cards...),
		Combo: combo,
	})
	if len(g.TrickPlays) == g.Players {
		g.resolveTrick()
	} else {
		g.Turn = (g.Turn + 1) % g.Players
	}
	return nil
}

func (g *Game) resolveTrick() {
	plays := make([][]Card, len(g.TrickPlays))
	for i, p := range g.TrickPlays {
		plays[i] = p.Cards
	}
	widx := ResolveTrick(plays, g.TrumpSuit)
	win := g.TrickPlays[widx]
	pts := 0
	for _, p := range g.TrickPlays {
		for _, c := range p.Cards {
			pts += PointValue(c)
		}
	}
	isXian := win.Seat != g.Declarer
	if isXian {
		g.XianPoints += pts
		for _, p := range g.TrickPlays {
			for _, c := range p.Cards {
				if PointValue(c) > 0 {
					g.XianCaptured = append(g.XianCaptured, c) // 记录捡到的分牌
				}
			}
		}
	}

	handsEmpty := true
	for _, h := range g.Hands {
		if len(h) > 0 {
			handsEmpty = false
			break
		}
	}
	if handsEmpty && isXian && win.Combo != nil && win.Combo.Group == "TRUMP" {
		// 底牌捡分:最后一墩闲家用主牌赢 → 翻底捡分;对子/拖拉机 ×2,单牌 ×1
		kp := 0
		for _, c := range g.Buried {
			kp += PointValue(c)
		}
		mult := 2
		if win.Combo.Type == "single" || win.Combo.Type == "throw" {
			mult = 1 // 甩牌本质是单牌集合,不翻倍
		}
		g.LastTrickBonus = kp * mult
		g.XianPoints += g.LastTrickBonus
		for _, c := range g.Buried {
			if PointValue(c) > 0 {
				g.XianCaptured = append(g.XianCaptured, c)
			}
		}
	}

	g.Tricks = append(g.Tricks, Trick{Plays: g.TrickPlays, WinnerSeat: win.Seat, Points: pts})
	g.TrickPlays = nil
	g.Leader = win.Seat
	g.Turn = win.Seat
	g.LeadCombo = nil
	if handsEmpty {
		g.finishHand()
	}
}

// ---------- 结算 ----------

func (g *Game) finishHand() {
	L := 200 - g.Contract
	x := g.XianPoints
	var perXian int // 闲家视角的底数(正=闲家赢,负=闲家输)
	var label string
	switch {
	case x == 0:
		perXian, label = -2, "庄家光头"
	case x < L:
		perXian, label = -1, "庄家赢"
	case x == L:
		perXian, label = 0, "平手"
	default:
		perXian = 1 + (x-L-1)/30
		label = "闲家赢(" + strconv.Itoa(perXian) + "档)"
	}

	stake := BaseStake(g.Contract)
	deltas := make([]int, g.Players)
	zhuang := 0
	for s := 0; s < g.Players; s++ {
		if s == g.Declarer {
			continue
		}
		deltas[s] = perXian * stake
		zhuang -= perXian * stake
	}
	deltas[g.Declarer] = zhuang
	for s := 0; s < g.Players; s++ {
		g.Scores[s] += deltas[s]
	}

	// 下局起喊:庄家输(闲家赢)→ 庄家下家;否则庄家
	if x > L {
		g.FirstBidder = (g.Declarer + 1) % g.Players
	} else {
		g.FirstBidder = g.Declarer
	}

	g.Result = &Result{
		Declarer: g.Declarer, Contract: g.Contract, Line: L,
		XianPoints: x, LastTrickBonus: g.LastTrickBonus,
		Label: label, PerXian: perXian, Stake: stake,
		Deltas: deltas, Scores: append([]int(nil), g.Scores...),
	}
	g.Phase = "done"
}
