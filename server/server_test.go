// server_test.go — 端到端集成测试:真 WebSocket 客户端 × 2 + 电脑补位,
// 打完整局(喊分→亮主→扣底→出牌→结算→下一局),再测掉线重连。
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"biaofen/server/game"
)

type joinedMsg struct {
	Type  string `json:"type"`
	Room  string `json:"room"`
	Seat  int    `json:"seat"`
	Token string `json:"token"`
}

type tClient struct {
	t     *testing.T
	conn  *websocket.Conn
	wmu   sync.Mutex // gorilla 不允许并发写同一连接
	seat  int
	token string
	room  string
}

func dialWS(t *testing.T, srv *httptest.Server) *tClient {
	t.Helper()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	conn, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return &tClient{t: t, conn: conn}
}

func (c *tClient) send(v any) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if err := c.conn.WriteJSON(v); err != nil {
		c.t.Errorf("write: %v", err)
	}
}

// 读到指定 type 的消息为止(其余缓存忽略);返回原始 JSON
func (c *tClient) waitFor(typ string, timeout time.Duration) map[string]json.RawMessage {
	c.t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		c.conn.SetReadDeadline(deadline)
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			c.t.Fatalf("等 %s 超时/出错: %v", typ, err)
		}
		var probe struct {
			Type string `json:"type"`
			Msg  string `json:"msg"`
		}
		json.Unmarshal(data, &probe)
		if probe.Type == "error" {
			c.t.Fatalf("服务器报错: %s", probe.Msg)
		}
		if probe.Type == typ {
			var m map[string]json.RawMessage
			json.Unmarshal(data, &m)
			return m
		}
	}
}

func (c *tClient) join(srvRoom, name, token string) {
	c.send(map[string]any{"type": "join", "room": srvRoom, "name": name, "token": token})
	raw := c.waitFor("joined", 5*time.Second)
	var j joinedMsg
	b, _ := json.Marshal(raw)
	json.Unmarshal(b, &j)
	c.seat, c.token, c.room = mustInt(raw["seat"]), mustStr(raw["token"]), mustStr(raw["room"])
}

func mustInt(r json.RawMessage) int {
	var v int
	json.Unmarshal(r, &v)
	return v
}
func mustStr(r json.RawMessage) string {
	var v string
	json.Unmarshal(r, &v)
	return v
}

// reactLoop 按视图驱动一个"真人":轮到自己就用 AI 决策出合法动作;
// 观察到 done 后向 doneCh 发结果并退出。全程校验打码不泄漏。
func (c *tClient) reactLoop(doneCh chan<- *View) {
	lastSig := ""
	deadline := time.Now().Add(60 * time.Second)
	for {
		c.conn.SetReadDeadline(deadline)
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return // 连接被测试主动关闭或超时
		}
		var probe struct{ Type string }
		json.Unmarshal(data, &probe)
		if probe.Type != "state" {
			continue
		}
		var v View
		if err := json.Unmarshal(data, &v); err != nil {
			c.t.Errorf("解析 state: %v", err)
			continue
		}
		// —— 打码校验:自己的手牌数与 counts 一致;非庄家看不到 kittyIds;没结束看不到 buried
		if v.Started && v.Phase != "" && v.Phase != "done" {
			if len(v.Buried) != 0 {
				c.t.Errorf("未结束却看到底牌!")
			}
			if v.MySeat != v.Declarer && len(v.KittyIDs) != 0 {
				c.t.Errorf("非庄家看到 kittyIds!")
			}
			if v.Counts != nil && len(v.Hand) != v.Counts[v.MySeat] {
				c.t.Errorf("手牌数与 counts 不一致: %d vs %d", len(v.Hand), v.Counts[v.MySeat])
			}
		}
		if v.Phase == "done" {
			select {
			case doneCh <- &v:
			default:
			}
			continue
		}
		sig := fmt.Sprintf("%s|%d|%d|%d|%d|%d|%d", v.Phase, v.HandNo, v.BidTurn, v.HighBid, v.Turn, len(v.TrickPlays), v.TricksPlayed)
		if sig == lastSig {
			continue // 已对这个状态出过手,忽略重复广播
		}
		acted := true
		switch {
		case v.Phase == "bidding" && v.BidTurn == v.MySeat:
			c.send(map[string]any{"type": "bid", "amount": 0}) // 一律不喊,让局面走下去
		case v.Phase == "declare" && v.Declarer == v.MySeat:
			c.send(map[string]any{"type": "trump", "suit": "S"})
		case v.Phase == "kitty" && v.Declarer == v.MySeat:
			ids := make([]string, v.KittySize)
			for i := 0; i < v.KittySize; i++ {
				ids[i] = v.Hand[i].ID
			}
			c.send(map[string]any{"type": "bury", "ids": ids})
		case v.Phase == "play" && v.Turn == v.MySeat:
			g := c.gameFromView(&v)
			var cards []game.Card
			if len(v.TrickPlays) == 0 {
				cards = game.AiLead(g, v.MySeat)
			} else {
				cards = game.AiFollow(g, v.MySeat)
			}
			ids := make([]string, len(cards))
			for i, cd := range cards {
				ids[i] = cd.ID
			}
			c.send(map[string]any{"type": "play", "ids": ids})
		default:
			acted = false
		}
		if acted {
			lastSig = sig
		}
	}
}

// 用视图重建一个够 AI 决策用的 Game(只填自己看得到的信息)
func (c *tClient) gameFromView(v *View) *game.Game {
	hands := make([][]game.Card, v.Players)
	hands[v.MySeat] = v.Hand
	var lead *game.Combo
	if len(v.TrickPlays) > 0 {
		lead = v.TrickPlays[0].Combo
	}
	return &game.Game{
		Players: v.Players, TrumpSuit: v.TrumpSuit, Declarer: v.Declarer,
		Turn: v.Turn, Hands: hands, TrickPlays: v.TrickPlays, LeadCombo: lead,
	}
}

func TestFullGameTwoHumansPlusBots(t *testing.T) {
	hub := NewHub()
	hub.botScale = 0 // AI 秒出,加速测试
	srv := httptest.NewServer(newMux(hub, http.Dir(".")))
	defer srv.Close()

	// c1 建房(4 人),c2 加入,剩两个座位由电脑补
	c1 := dialWS(t, srv)
	c1.send(map[string]any{"type": "create", "players": 4, "name": "甲"})
	raw := c1.waitFor("joined", 5*time.Second)
	c1.seat, c1.token, c1.room = mustInt(raw["seat"]), mustStr(raw["token"]), mustStr(raw["room"])
	if c1.seat != 0 {
		t.Fatalf("房主应坐 0 号位, got %d", c1.seat)
	}

	c2 := dialWS(t, srv)
	c2.join(c1.room, "乙", "")
	if c2.seat != 1 {
		t.Fatalf("第二人应坐 1 号位, got %d", c2.seat)
	}

	done1 := make(chan *View, 1)
	done2 := make(chan *View, 1)
	go c1.reactLoop(done1)
	go c2.reactLoop(done2)

	c1.send(map[string]any{"type": "start"})

	var final *View
	select {
	case final = <-done1:
	case <-time.After(60 * time.Second):
		t.Fatal("60s 内没打完一局")
	}
	if final.Result == nil {
		t.Fatal("done 状态缺 result")
	}
	sum := 0
	for _, d := range final.Result.Deltas {
		sum += d
	}
	if sum != 0 {
		t.Fatalf("结算不守恒: %v", final.Result.Deltas)
	}
	if len(final.Buried) != final.KittySize {
		t.Fatalf("结束后应翻开 %d 张底牌, got %d", final.KittySize, len(final.Buried))
	}
	t.Logf("第一局完成: %s (庄=座%d 喊%d 闲家捡%d)", final.Result.Label, final.Result.Declarer, final.Result.Contract, final.Result.XianPoints)

	// 下一局:任一真人可开
	c2.send(map[string]any{"type": "next"})
	select {
	case v2 := <-done2:
		_ = v2
	case <-time.After(60 * time.Second):
		t.Fatal("第二局 60s 内没打完")
	}
	t.Log("第二局也完整跑完(积分跨局累计)")
}

func TestReconnectKeepsSeat(t *testing.T) {
	hub := NewHub()
	hub.botScale = 0 // AI 秒出,加速测试
	srv := httptest.NewServer(newMux(hub, http.Dir(".")))
	defer srv.Close()

	c1 := dialWS(t, srv)
	c1.send(map[string]any{"type": "create", "players": 3, "name": "甲"})
	raw := c1.waitFor("joined", 5*time.Second)
	c1.seat, c1.token, c1.room = mustInt(raw["seat"]), mustStr(raw["token"]), mustStr(raw["room"])

	c2 := dialWS(t, srv)
	c2.join(c1.room, "乙", "")
	oldSeat, oldToken := c2.seat, c2.token

	done1 := make(chan *View, 1)
	go c1.reactLoop(done1)
	c1.send(map[string]any{"type": "start"})

	// 等乙确认"对局已开始"再掉线(大厅阶段掉线是让座,不保留座位)
	deadline := time.Now().Add(5 * time.Second)
	for {
		c2.conn.SetReadDeadline(deadline)
		_, data, err := c2.conn.ReadMessage()
		if err != nil {
			t.Fatalf("等开局状态失败: %v", err)
		}
		var v View
		if json.Unmarshal(data, &v) == nil && v.Type == "state" && v.Started {
			break
		}
	}
	// 乙掉线 → AI 托管接管;甲那边整局照打不误
	c2.conn.Close()

	select {
	case <-done1:
	case <-time.After(60 * time.Second):
		t.Fatal("乙掉线后 60s 没打完(托管没生效?)")
	}

	// 乙重连:凭 token 回原座位
	c3 := dialWS(t, srv)
	c3.join(c1.room, "乙", oldToken)
	if c3.seat != oldSeat {
		t.Fatalf("重连应回座位 %d, got %d", oldSeat, c3.seat)
	}
	if c3.token != oldToken {
		t.Fatalf("重连后 token 应不变")
	}
	// 重连后应能收到当前状态
	c3.waitFor("state", 5*time.Second)
	t.Log("掉线→托管打完→重连回座 全链路 OK")
}

func TestJoinErrors(t *testing.T) {
	srv := httptest.NewServer(newMux(NewHub(), http.Dir(".")))
	defer srv.Close()

	// 不存在的房间
	c := dialWS(t, srv)
	c.send(map[string]any{"type": "join", "room": "ZZZZ", "name": "x"})
	c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, data, err := c.conn.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(string(data), "不存在") {
		t.Fatalf("应提示房间不存在, got %s", data)
	}
}
