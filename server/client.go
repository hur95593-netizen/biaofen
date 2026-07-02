// client.go — 一条 WebSocket 连接的读/写泵(gorilla 标准模式)
package main

import (
	"encoding/json"
	"log"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const (
	writeWait  = 10 * time.Second
	pongWait   = 60 * time.Second
	pingPeriod = 45 * time.Second
	maxMsgSize = 8 << 10
)

// ClientMsg 客户端 → 服务器的所有消息(按 Type 取用字段)
type ClientMsg struct {
	Type    string   `json:"type"`    // create|join|start|bid|trump|bury|play|next
	Players int      `json:"players"` // create: 3|4
	Name    string   `json:"name"`    // create/join
	Room    string   `json:"room"`    // join
	Token   string   `json:"token"`   // join(重连)
	Amount  int      `json:"amount"`  // bid(0 = 不喊)
	Suit    string   `json:"suit"`    // trump
	IDs     []string `json:"ids"`     // bury/play
}

type Client struct {
	hub  *Hub
	conn *websocket.Conn
	send chan []byte
	room *Room // 仅 readPump goroutine 读写
}

// trySend 非阻塞发送;缓冲满(慢客户端)则断开它,防止拖垮整桌
func (c *Client) trySend(b []byte) {
	select {
	case c.send <- b:
	default:
		c.closeSend()
	}
}

func (c *Client) closeSend() {
	defer func() { recover() }() // 已关闭则忽略
	close(c.send)
}

func (c *Client) sendJSON(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("marshal: %v", err)
		return
	}
	c.trySend(b)
}

func (c *Client) sendError(msg string) {
	c.sendJSON(map[string]any{"type": "error", "msg": msg})
}

func cleanName(s string) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) > 12 {
		r = r[:12]
	}
	if len(r) == 0 {
		return "玩家"
	}
	return string(r)
}

func (c *Client) readPump() {
	defer func() {
		if c.room != nil {
			c.room.post(evClose{c: c})
		}
		c.conn.Close()
	}()
	c.conn.SetReadLimit(maxMsgSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		var m ClientMsg
		if err := json.Unmarshal(data, &m); err != nil {
			c.sendError("消息格式错误")
			continue
		}
		if c.room == nil {
			// 第一条消息必须是 create / join
			switch m.Type {
			case "create":
				if m.Players != 3 && m.Players != 4 {
					c.sendError("人数必须是 3 或 4")
					continue
				}
				r := c.hub.CreateRoom(m.Players)
				c.room = r
				r.post(evJoin{c: c, name: cleanName(m.Name)})
			case "join":
				code := strings.ToUpper(strings.TrimSpace(m.Room))
				r := c.hub.Get(code)
				if r == nil {
					c.sendError("房间不存在(可能已解散)")
					continue
				}
				c.room = r
				r.post(evJoin{c: c, name: cleanName(m.Name), token: m.Token})
			default:
				c.sendError("请先创建或加入房间")
			}
		} else {
			c.room.post(evMsg{c: c, m: m})
		}
	}
}

func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()
	for {
		select {
		case msg, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
