// ab_test.go — 3 人局 AI 策略 A/B 对战台:让新旧策略互打,量化每个改动的净收益。
// 用法:go test ./server/game/ -run TestAB3P -v
package game

import (
	"math/rand"
	"testing"
)

type abStats struct {
	zhuangWins, xianWins, draws int
	xianPointsSum               int
	zhuangDelta                 int64 // 庄家累计净底分(正 = 庄家整体赚)
}

// declV4 控制庄家侧策略版本,defV4 控制闲家侧;开关按角色生效,可在同一局里混用
func runAB(t *testing.T, declV4, defV4 bool, hands int, seed int64) abStats {
	t.Helper()
	oldZ, oldX := aiV4Zhuang, aiV4Xian
	defer func() { aiV4Zhuang, aiV4Xian = oldZ, oldX }()
	aiV4Zhuang, aiV4Xian = declV4, defV4

	g := NewGame(3, rand.New(rand.NewSource(seed)))
	var st abStats
	for i := 0; i < hands; i++ {
		r := playOneHand(t, g)
		st.xianPointsSum += r.XianPoints
		st.zhuangDelta += int64(r.Deltas[r.Declarer])
		switch {
		case r.PerXian == 0:
			st.draws++
		case r.PerXian < 0:
			st.zhuangWins++
		default:
			st.xianWins++
		}
	}
	return st
}

func TestAB3P(t *testing.T) {
	const N = 2000
	for _, tc := range []struct {
		name string
		z, x bool
	}{
		{"基线  v3庄 vs v3闲", false, false},
		{"庄升级 v4庄 vs v3闲", true, false},
		{"闲升级 v3庄 vs v4闲", false, true},
		{"全升级 v4庄 vs v4闲", true, true},
	} {
		st := runAB(t, tc.z, tc.x, N, 2026)
		t.Logf("%s:庄胜 %4.1f%%  闲家场均捡分 %5.1f  庄家累计净底分 %+d",
			tc.name, float64(st.zhuangWins)*100/float64(N),
			float64(st.xianPointsSum)/float64(N), st.zhuangDelta)
	}
}
