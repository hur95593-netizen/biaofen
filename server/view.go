// view.go — 按座位打码的对局视图:只发本人手牌 + 公共信息,
// 其他人只给张数;底牌只在本局结束后翻开。防作弊的关键在这里。
package main

import "biaofen/server/game"

type SeatView struct {
	Taken     bool   `json:"taken"`
	Bot       bool   `json:"bot"`
	Name      string `json:"name"`
	Connected bool   `json:"connected"`
}

type View struct {
	Type    string     `json:"type"` // "state"
	Room    string     `json:"room"`
	Players int        `json:"players"`
	Started bool       `json:"started"`
	Seats   []SeatView `json:"seats"`
	HostSeat int       `json:"hostSeat"`
	MySeat   int       `json:"mySeat"`

	Phase  string `json:"phase"` // "" = 大厅
	HandNo int    `json:"handNo"`
	Scores []int  `json:"scores"`

	BidTurn      int    `json:"bidTurn"`
	HighBid      int    `json:"highBid"`
	HighBidder   int    `json:"highBidder"`
	Passed       []bool `json:"passed"`
	NextBidLevel int    `json:"nextBidLevel"`

	Declarer  int      `json:"declarer"`
	Contract  int      `json:"contract"`
	TrumpSuit string   `json:"trumpSuit"`
	KittySize int      `json:"kittySize"`
	KittyIDs  []string `json:"kittyIds,omitempty"` // 仅庄家扣底阶段:标记哪些是底牌

	Turn         int         `json:"turn"`
	Leader       int         `json:"leader"`
	Hand         []game.Card `json:"hand"`
	Counts       []int       `json:"counts"`
	TrickPlays   []game.Play `json:"trickPlays"`
	LastTrick    *game.Trick `json:"lastTrick"`
	TricksPlayed int         `json:"tricksPlayed"`
	XianPoints   int         `json:"xianPoints"`
	XianCaptured []game.Card `json:"xianCaptured"`

	Result *game.Result `json:"result"`
	Buried []game.Card  `json:"buried,omitempty"` // 仅结束后翻开
}

func buildView(r *Room, mySeat int) *View {
	v := &View{
		Type: "state", Room: r.code, Players: r.players, Started: r.started,
		HostSeat: r.hostSeat(), MySeat: mySeat,
		Seats:  make([]SeatView, r.players),
		Scores: make([]int, r.players),
		// 数值型"空"统一 -1,前端好判断
		BidTurn: -1, HighBidder: -1, Declarer: -1, Turn: -1, Leader: -1,
	}
	for i := range r.seats {
		s := &r.seats[i]
		v.Seats[i] = SeatView{Taken: s.Taken, Bot: s.Bot, Name: s.Name, Connected: s.Bot || s.Client != nil}
	}
	g := r.game
	if g == nil {
		return v
	}

	v.Phase = g.Phase
	v.HandNo = g.HandNo
	v.Scores = g.Scores
	v.BidTurn = g.BidTurn
	v.HighBid = g.HighBid
	v.HighBidder = g.HighBidder
	v.Passed = g.Passed
	v.NextBidLevel = g.NextBidLevel()
	v.Declarer = g.Declarer
	v.Contract = g.Contract
	v.TrumpSuit = g.TrumpSuit
	v.KittySize = g.KittySize
	v.Turn = g.Turn
	v.Leader = g.Leader
	v.XianPoints = g.XianPoints
	v.XianCaptured = g.XianCaptured
	v.TrickPlays = g.TrickPlays
	v.TricksPlayed = len(g.Tricks)
	if n := len(g.Tricks); n > 0 {
		v.LastTrick = &g.Tricks[n-1]
	}

	v.Hand = g.Hands[mySeat] // 只发本人手牌
	v.Counts = make([]int, r.players)
	for i, h := range g.Hands {
		v.Counts[i] = len(h)
	}

	if g.Phase == "kitty" && mySeat == g.Declarer {
		v.KittyIDs = make([]string, len(g.Kitty))
		for i, c := range g.Kitty {
			v.KittyIDs[i] = c.ID
		}
	}
	if g.Phase == "done" {
		v.Result = g.Result
		v.Buried = g.Buried
	}
	return v
}
