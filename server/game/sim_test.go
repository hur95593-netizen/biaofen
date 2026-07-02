// sim_test.go — 全 AI 自动对局(移植自 test/sim.js):验证整局流程、合法性、结算守恒
package game

import (
	"math/rand"
	"testing"
)

func playOneHand(t *testing.T, g *Game) *Result {
	t.Helper()
	g.StartHand()
	guard := 0
	for g.Phase == "bidding" {
		if err := g.PlaceBid(g.BidTurn, AiBid(g, g.BidTurn)); err != nil {
			t.Fatalf("喊分出错: %v", err)
		}
		if guard++; guard > 50 {
			t.Fatal("喊分死循环")
		}
	}
	if err := g.DeclareTrump(AiTrump(g, g.Declarer)); err != nil {
		t.Fatalf("亮主出错: %v", err)
	}
	if err := g.BuryCards(AiBury(g, g.Declarer)); err != nil {
		t.Fatalf("扣底出错: %v", err)
	}
	guard = 0
	for g.Phase == "play" {
		seat := g.Turn
		var cards []Card
		if g.IsLeadTurn() {
			cards = AiLead(g, seat)
		} else {
			cards = AiFollow(g, seat)
		}
		if !g.ValidatePlay(seat, cards) {
			t.Fatalf("AI 给出非法牌: 局%d 座%d 牌%v 首攻=%v", g.HandNo, seat, cards, g.IsLeadTurn())
		}
		if err := g.PlayCards(seat, cards); err != nil {
			t.Fatalf("出牌出错: %v", err)
		}
		if guard++; guard > 10000 {
			t.Fatal("出牌死循环")
		}
	}
	return g.Result
}

func simMany(t *testing.T, players, hands int, seed int64) {
	g := NewGame(players, rand.New(rand.NewSource(seed)))
	zhuangWins, xianWins, draws := 0, 0, 0
	for i := 0; i < hands; i++ {
		r := playOneHand(t, g)
		sum := 0
		for _, d := range r.Deltas {
			sum += d
		}
		if sum != 0 {
			t.Fatalf("局 %d 结算不守恒: %v", i+1, r.Deltas)
		}
		if r.XianPoints < 0 {
			t.Fatalf("闲家分为负: %d", r.XianPoints)
		}
		switch {
		case r.PerXian == 0:
			draws++
		case r.PerXian < 0:
			zhuangWins++
		default:
			xianWins++
		}
	}
	total := 0
	for _, s := range g.Scores {
		total += s
	}
	if total != 0 {
		t.Fatalf("累计积分不守恒: %v", g.Scores)
	}
	t.Logf("%d 人 × %d 局:庄家赢 %d,闲家赢 %d,平 %d,累计积分 %v", players, hands, zhuangWins, xianWins, draws, g.Scores)
}

func TestSim3Players(t *testing.T) { simMany(t, 3, 300, 99) }
func TestSim4Players(t *testing.T) { simMany(t, 4, 300, 99) }
