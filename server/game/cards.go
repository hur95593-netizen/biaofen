// Package game — 「飙分」规则引擎(1:1 移植自 src/cards.js 等,规则见 飙分-规则.md)。
package game

import (
	"fmt"
	"math/rand"
	"sort"
)

const (
	SmallJoker = 16
	BigJoker   = 17
)

var Suits = []string{"S", "H", "D", "C"} // ♠ ♥ ♦ ♣

// Card 的 JSON 字段与前端 src/cards.js 完全一致(id 格式 "S-5-0"),前后端直接互通。
type Card struct {
	Suit string `json:"suit"`
	Rank int    `json:"rank"`
	Copy int    `json:"copy"`
	ID   string `json:"id"`
}

func MakeCard(suit string, rank, copy int) Card {
	return Card{Suit: suit, Rank: rank, Copy: copy, ID: fmt.Sprintf("%s-%d-%d", suit, rank, copy)}
}

func (c Card) IsJoker() bool { return c.Suit == "JOKER" }

// 一副 54 张(52 + 大小王),两副共 108
func BuildDeck() []Card {
	cards := make([]Card, 0, 108)
	for copy := 0; copy < 2; copy++ {
		for _, s := range Suits {
			for r := 2; r <= 14; r++ {
				cards = append(cards, MakeCard(s, r, copy))
			}
		}
		cards = append(cards, MakeCard("JOKER", SmallJoker, copy))
		cards = append(cards, MakeCard("JOKER", BigJoker, copy))
	}
	return cards
}

// 常主:大小王、所有 3、所有 2;再加主花色全部 → 主牌
func IsTrump(c Card, trumpSuit string) bool {
	if c.IsJoker() {
		return true
	}
	if c.Rank == 3 || c.Rank == 2 {
		return true
	}
	return c.Suit == trumpSuit
}

// 分组:"TRUMP" 或 边花色字母("H"/"D"/"C"/"S")
func CardGroup(c Card, trumpSuit string) string {
	if IsTrump(c, trumpSuit) {
		return "TRUMP"
	}
	return c.Suit
}

// 组内「比大小」刻度(越大越强)——决定谁压谁。与「拖拉机相邻」是两套规则(见 TractorRankOf)。
// 主牌:大王200 > 小王199 > 主3 198 > 副3 197 > 主2 196 > 副2 195 > 主A 194 …… 主4 184。
func Strength(c Card, trumpSuit string) int {
	if CardGroup(c, trumpSuit) != "TRUMP" {
		return c.Rank // 边牌:4..14
	}
	if c.Rank == BigJoker {
		return 200
	}
	if c.Rank == SmallJoker {
		return 199
	}
	mainSuit := c.Suit == trumpSuit
	switch c.Rank {
	case 3:
		if mainSuit {
			return 198
		}
		return 197 // 主3 > 副3
	case 2:
		if mainSuit {
			return 196
		}
		return 195 // 主2 > 副2(且所有3 > 所有2)
	}
	return c.Rank + 180 // 主花色 4..14(A) → 184..194(均 < 副2 195)
}

// TRank 「拖拉机相邻」刻度——只管连不连,与比大小分开。
// 同 Lane(同花色/同孤岛)且 Pos 差 1 才相连。Alt=0 表示无备选位;
// 主 A「两头都连」→ Pos:1 兼 Alt:14(接 2 也接 K)。王自成孤岛(16/17 相邻)。
type TRank struct {
	Lane string
	Pos  int
	Alt  int
}

func TractorRankOf(c Card, trumpSuit string) TRank {
	if c.IsJoker() {
		return TRank{Lane: "JOKER", Pos: c.Rank}
	}
	if IsTrump(c, trumpSuit) {
		if c.Rank == 14 {
			return TRank{Lane: "T-" + c.Suit, Pos: 1, Alt: 14} // 主A(A 必为主花色)
		}
		return TRank{Lane: "T-" + c.Suit, Pos: c.Rank} // 主3=3、主2=2、…、主K=13
	}
	return TRank{Lane: c.Suit, Pos: c.Rank} // 边牌 ace-high 4..14
}

func Shuffle(cards []Card, rng *rand.Rand) []Card {
	a := append([]Card(nil), cards...)
	for i := len(a) - 1; i > 0; i-- {
		j := rng.Intn(i + 1)
		a[i], a[j] = a[j], a[i]
	}
	return a
}

type DealResult struct {
	Hands     [][]Card
	Kitty     []Card
	KittySize int
	PerHand   int
}

// 发牌。players: 3 或 4。4 人 → 每人 25、底牌 8;3 人 → 每人 33、底牌 9。
func Deal(cards []Card, players int) DealResult {
	kittySize := 9
	if players == 4 {
		kittySize = 8
	}
	perHand := (len(cards) - kittySize) / players
	hands := make([][]Card, players)
	i := 0
	for p := 0; p < players; p++ {
		hands[p] = make([]Card, 0, perHand)
		for k := 0; k < perHand; k++ {
			hands[p] = append(hands[p], cards[i])
			i++
		}
	}
	return DealResult{Hands: hands, Kitty: append([]Card(nil), cards[i:]...), KittySize: kittySize, PerHand: perHand}
}

// SideSuitOrder 边花色展示顺序:按主花色动态排列,保证相邻花色黑红交错(不易看错)
func SideSuitOrder(trumpSuit string) []string {
	switch trumpSuit {
	case "S":
		return []string{"H", "C", "D"} // 红黑红
	case "C":
		return []string{"H", "S", "D"} // 红黑红
	case "H":
		return []string{"S", "D", "C"} // 黑红黑
	case "D":
		return []string{"S", "H", "C"} // 黑红黑
	}
	return []string{"S", "H", "C", "D"} // 未亮主:黑红黑红
}

// 整理手牌(展示用):主牌在前,组内从大到小;相同的牌相邻(对子不被拆)
func SortHand(hand []Card, trumpSuit string) []Card {
	groupOrder := map[string]int{"TRUMP": 0}
	for i, s := range SideSuitOrder(trumpSuit) {
		groupOrder[s] = i + 1
	}
	suitOrder := map[string]int{"S": 0, "H": 1, "D": 2, "C": 3, "JOKER": 4}
	a := append([]Card(nil), hand...)
	sort.SliceStable(a, func(i, j int) bool {
		ga, gb := CardGroup(a[i], trumpSuit), CardGroup(a[j], trumpSuit)
		if groupOrder[ga] != groupOrder[gb] {
			return groupOrder[ga] < groupOrder[gb]
		}
		sa, sb := Strength(a[i], trumpSuit), Strength(a[j], trumpSuit)
		if sa != sb {
			return sa > sb
		}
		if a[i].Suit != a[j].Suit {
			return suitOrder[a[i].Suit] < suitOrder[a[j].Suit]
		}
		if a[i].Rank != a[j].Rank {
			return a[i].Rank > a[j].Rank
		}
		return a[i].Copy < a[j].Copy
	})
	return a
}
