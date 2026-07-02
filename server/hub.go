// hub.go — 房间注册表:按房间码创建/查找;房间自身超时后从这里摘除
package main

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
)

// 房间码字符集:去掉易混淆的 I/L/O/0/1
const codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

func genCode(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	for i := range b {
		b[i] = codeAlphabet[int(b[i])%len(codeAlphabet)]
	}
	return string(b)
}

func genToken() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

type Hub struct {
	mu    sync.Mutex
	rooms map[string]*Room
	// AI 出手延迟缩放(创建房间时拷贝进 Room;集成测试置 0 → AI 秒出)。
	// 只应在创建任何房间之前设置。
	botScale float64
}

func NewHub() *Hub {
	return &Hub{rooms: map[string]*Room{}, botScale: 1.0}
}

func (h *Hub) CreateRoom(players int) *Room {
	h.mu.Lock()
	defer h.mu.Unlock()
	for {
		code := genCode(4)
		if _, ok := h.rooms[code]; ok {
			continue
		}
		r := newRoom(h, code, players)
		h.rooms[code] = r
		go r.run()
		return r
	}
}

func (h *Hub) Get(code string) *Room {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.rooms[code]
}

func (h *Hub) Remove(code string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.rooms, code)
}

func (h *Hub) Count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.rooms)
}
