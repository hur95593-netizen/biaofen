// room.go — 一桌 = 一个 goroutine 的事件循环(actor)。
// 所有牌局状态只被本房间的 goroutine 触碰 → 无锁、天然串行;
// 房间之间完全独立,支撑高并发。
package main

import (
	"log"
	"math/rand"
	"time"

	"biaofen/server/game"
)

const roomIdleTimeout = 10 * time.Minute // 无真人在线超过此时长 → 解散

// ---- 事件(投递进 inbox) ----
type evJoin struct {
	c     *Client
	name  string
	token string // 非空 = 尝试重连
}
type evMsg struct {
	c *Client
	m ClientMsg
}
type evClose struct{ c *Client }
type evBot struct{ seq int }

type Seat struct {
	Taken  bool
	Bot    bool
	Name   string
	Token  string
	Client *Client // nil = 掉线(真人)或电脑
}

type Room struct {
	hub     *Hub
	code    string
	players int
	inbox   chan any
	done    chan struct{}

	seats     []Seat
	game      *game.Game
	started   bool
	botSeq    int       // 递增序号,作废旧的 AI 定时器
	botScale  float64   // AI 延迟缩放(建房时从 Hub 拷贝,之后只读)
	lastHuman time.Time // 最后一次有真人在线的时间(仅房间 goroutine 访问)
}

func newRoom(h *Hub, code string, players int) *Room {
	return &Room{
		hub:       h,
		code:      code,
		players:   players,
		inbox:     make(chan any, 64),
		done:      make(chan struct{}),
		seats:     make([]Seat, players),
		botScale:  h.botScale,
		lastHuman: time.Now(),
	}
}

// post 从任意 goroutine 安全投递事件(房间已解散则丢弃)
func (r *Room) post(ev any) {
	select {
	case r.inbox <- ev:
	case <-r.done:
	}
}

func (r *Room) run() {
	idle := time.NewTicker(time.Minute)
	defer idle.Stop()
	for {
		select {
		case ev := <-r.inbox:
			switch e := ev.(type) {
			case evJoin:
				r.handleJoin(e)
			case evMsg:
				r.handleMsg(e)
			case evClose:
				r.handleClose(e)
			case evBot:
				r.handleBot(e)
			}
		case <-idle.C:
			if r.anyHumanConnected() {
				r.lastHuman = time.Now()
			} else if time.Since(r.lastHuman) > roomIdleTimeout {
				r.shutdown()
				return
			}
		}
	}
}

func (r *Room) shutdown() {
	close(r.done)
	for i := range r.seats {
		if c := r.seats[i].Client; c != nil {
			c.closeSend()
		}
	}
	r.hub.Remove(r.code)
	log.Printf("房间 %s 解散(剩 %d 间)", r.code, r.hub.Count())
}

func (r *Room) anyHumanConnected() bool {
	for i := range r.seats {
		if r.seats[i].Taken && !r.seats[i].Bot && r.seats[i].Client != nil {
			return true
		}
	}
	return false
}

// 房主 = 座位号最小的真人
func (r *Room) hostSeat() int {
	for i := range r.seats {
		if r.seats[i].Taken && !r.seats[i].Bot {
			return i
		}
	}
	return -1
}

func (r *Room) seatOf(c *Client) int {
	for i := range r.seats {
		if r.seats[i].Client == c {
			return i
		}
	}
	return -1
}

// ---- 加入 / 重连 ----

func (r *Room) handleJoin(e evJoin) {
	// 1) 带 token → 重连回原座位(对局中掉线/刷新)
	if e.token != "" {
		for i := range r.seats {
			s := &r.seats[i]
			if s.Taken && !s.Bot && s.Token == e.token {
				if s.Client != nil {
					s.Client.closeSend() // 同 token 新连接顶掉旧连接
				}
				s.Client = e.c
				r.lastHuman = time.Now()
				e.c.sendJSON(map[string]any{"type": "joined", "room": r.code, "seat": i, "token": s.Token, "players": r.players})
				r.broadcast()
				r.emit("reconnected", i, s.Name)
				r.scheduleBots() // 若正轮到他,作废托管定时器由 handleBot 的在线检查兜底
				return
			}
		}
		// token 对不上(房间已换代)→ 当新玩家处理,落到下面
	}
	if r.started {
		e.c.sendError("对局已开始,无法加入")
		return
	}
	for i := range r.seats {
		s := &r.seats[i]
		if !s.Taken {
			*s = Seat{Taken: true, Name: e.name, Token: genToken(), Client: e.c}
			r.lastHuman = time.Now()
			e.c.sendJSON(map[string]any{"type": "joined", "room": r.code, "seat": i, "token": s.Token, "players": r.players})
			r.broadcast()
			r.emit("joined", i, s.Name)
			return
		}
	}
	e.c.sendError("房间已满")
}

// ---- 掉线 ----

func (r *Room) handleClose(e evClose) {
	i := r.seatOf(e.c) // 只认"当前连接":旧连接迟到的 close 不会误踢已重连的玩家
	if i < 0 {
		return
	}
	s := &r.seats[i]
	s.Client = nil
	if !r.started {
		name := s.Name
		*s = Seat{} // 大厅阶段:直接让座
		r.broadcast()
		r.emit("left", i, name)
		return
	}
	// 对局中:保座位,AI 托管
	r.broadcast()
	r.emit("disconnected", i, s.Name)
	r.scheduleBots()
}

// ---- 玩家消息 ----

func (r *Room) handleMsg(e evMsg) {
	seat := r.seatOf(e.c)
	if seat < 0 {
		e.c.sendError("未入座")
		return
	}
	r.lastHuman = time.Now()
	var err error
	switch e.m.Type {
	case "start":
		err = r.doStart(seat)
	case "bid":
		err = r.applyBid(seat, e.m.Amount)
	case "trump":
		err = r.applyTrump(seat, e.m.Suit)
	case "bury":
		err = r.applyBury(seat, e.m.IDs)
	case "play":
		err = r.applyPlay(seat, e.m.IDs)
	case "next":
		err = r.doNext(seat)
	default:
		return // 未知消息忽略
	}
	if err != nil {
		e.c.sendError(err.Error())
		return
	}
	r.broadcast()
	r.scheduleBots()
}

func (r *Room) doStart(seat int) error {
	if r.started {
		return errString("对局已开始")
	}
	if seat != r.hostSeat() {
		return errString("只有房主能开始")
	}
	for i := range r.seats {
		if !r.seats[i].Taken {
			r.seats[i] = Seat{Taken: true, Bot: true, Name: botName(i)}
		}
	}
	r.started = true
	r.game = game.NewGame(r.players, rand.New(rand.NewSource(time.Now().UnixNano())))
	r.game.StartHand()
	log.Printf("房间 %s 开局(%d 人)", r.code, r.players)
	return nil
}

func (r *Room) doNext(seat int) error {
	if r.game == nil || r.game.Phase != "done" {
		return errString("本局还没结束")
	}
	r.game.StartHand()
	return nil
}

func (r *Room) applyBid(seat, amount int) error {
	if r.game == nil {
		return errString("对局未开始")
	}
	if err := r.game.PlaceBid(seat, amount); err != nil {
		return err
	}
	r.emit("bid", seat, amount)
	if r.game.Phase != "bidding" {
		r.emit("declarerSet", r.game.Declarer, r.game.Contract)
	}
	return nil
}

func (r *Room) applyTrump(seat int, suit string) error {
	if r.game == nil || seat != r.game.Declarer {
		return errString("只有庄家能亮主")
	}
	ok := false
	for _, s := range game.Suits {
		if s == suit {
			ok = true
			break
		}
	}
	if !ok {
		return errString("无效花色")
	}
	if err := r.game.DeclareTrump(suit); err != nil {
		return err
	}
	r.emit("trump", seat, suit)
	return nil
}

func (r *Room) applyBury(seat int, ids []string) error {
	if r.game == nil || seat != r.game.Declarer {
		return errString("只有庄家能扣底")
	}
	cards, err := r.cardsByIDs(seat, ids)
	if err != nil {
		return err
	}
	if err := r.game.BuryCards(cards); err != nil {
		return err
	}
	r.emit("buried", seat, nil)
	return nil
}

func (r *Room) applyPlay(seat int, ids []string) error {
	if r.game == nil {
		return errString("对局未开始")
	}
	cards, err := r.cardsByIDs(seat, ids)
	if err != nil {
		return err
	}
	prev := len(r.game.Tricks)
	if err := r.game.PlayCards(seat, cards); err != nil {
		return err
	}
	if len(r.game.Tricks) > prev {
		tr := r.game.Tricks[len(r.game.Tricks)-1]
		r.emit("trick", tr.WinnerSeat, tr.Points)
	}
	if r.game.Phase == "done" {
		r.emit("result", r.game.Declarer, r.game.Result.Label)
	}
	return nil
}

// 把牌 ID 列表还原为该座位手中的牌(拒绝重复/不存在的 ID)
func (r *Room) cardsByIDs(seat int, ids []string) ([]game.Card, error) {
	byID := map[string]game.Card{}
	for _, c := range r.game.Hands[seat] {
		byID[c.ID] = c
	}
	seen := map[string]bool{}
	out := make([]game.Card, 0, len(ids))
	for _, id := range ids {
		c, ok := byID[id]
		if !ok || seen[id] {
			return nil, errString("所选的牌不在手中")
		}
		seen[id] = true
		out = append(out, c)
	}
	return out, nil
}

// ---- AI 驱动(电脑座位 + 掉线托管) ----

// 当前等待行动的座位;-1 = 无(大厅/已结束)
func (r *Room) pendingSeat() int {
	if !r.started || r.game == nil {
		return -1
	}
	switch r.game.Phase {
	case "bidding":
		return r.game.BidTurn
	case "declare", "kitty":
		return r.game.Declarer
	case "play":
		return r.game.Turn
	}
	return -1
}

func (r *Room) botDelay() time.Duration {
	g := r.game
	switch g.Phase {
	case "bidding":
		return 600 * time.Millisecond
	case "declare":
		return 900 * time.Millisecond
	case "kitty":
		return 1000 * time.Millisecond
	case "play":
		if len(g.TrickPlays) == 0 && len(g.Tricks) > 0 {
			return 1600 * time.Millisecond // 收墩后停一拍,给真人看清上一墩
		}
		return 700 * time.Millisecond
	}
	return 700 * time.Millisecond
}

// 每次状态变化后调用:若轮到 电脑/掉线真人 → 定时执行 AI 动作
func (r *Room) scheduleBots() {
	r.botSeq++
	seat := r.pendingSeat()
	if seat < 0 {
		return
	}
	s := &r.seats[seat]
	if !s.Bot && s.Client != nil {
		return // 在线真人自己操作
	}
	delay := r.botDelay()
	if !s.Bot {
		delay = 3 * time.Second // 掉线托管:多等一会,给重连留窗口
	}
	delay = time.Duration(float64(delay) * r.botScale)
	seq := r.botSeq
	time.AfterFunc(delay, func() { r.post(evBot{seq: seq}) })
}

func (r *Room) handleBot(e evBot) {
	if e.seq != r.botSeq {
		return // 状态已变,旧定时器作废
	}
	seat := r.pendingSeat()
	if seat < 0 {
		return
	}
	s := &r.seats[seat]
	if !s.Bot && s.Client != nil {
		return // 托管期间重连回来了 → 还给真人
	}
	g := r.game
	var err error
	switch g.Phase {
	case "bidding":
		err = r.applyBid(seat, game.AiBid(g, seat))
	case "declare":
		err = r.applyTrump(seat, game.AiTrump(g, seat))
	case "kitty":
		err = r.applyBury(seat, idsOf(game.AiBury(g, seat)))
	case "play":
		var cards []game.Card
		if g.IsLeadTurn() {
			cards = game.AiLead(g, seat)
		} else {
			cards = game.AiFollow(g, seat)
		}
		err = r.applyPlay(seat, idsOf(cards))
	}
	if err != nil {
		// AI 不应出非法牌(sim 测试保证);万一发生,记日志防卡死:兜底出最小合法牌会更复杂,先记录
		log.Printf("房间 %s AI 动作失败(座 %d, %s): %v", r.code, seat, g.Phase, err)
	}
	r.broadcast()
	r.scheduleBots()
}

func idsOf(cards []game.Card) []string {
	ids := make([]string, len(cards))
	for i, c := range cards {
		ids[i] = c.ID
	}
	return ids
}

func botName(i int) string {
	names := []string{"电脑·阿福", "电脑·大牛", "电脑·翠花", "电脑·二狗"}
	return names[i%len(names)]
}

// ---- 广播 ----

func (r *Room) broadcast() {
	for i := range r.seats {
		if c := r.seats[i].Client; c != nil {
			c.sendJSON(buildView(r, i))
		}
	}
}

// emit 发一条轻量事件(前端 toast 用)。data 按 kind 取义:bid=分数,trick=分数,trump=花色…
func (r *Room) emit(kind string, seat int, data any) {
	msg := map[string]any{"type": "event", "kind": kind, "seat": seat, "data": data}
	for i := range r.seats {
		if c := r.seats[i].Client; c != nil {
			c.sendJSON(msg)
		}
	}
}

type errString string

func (e errString) Error() string { return string(e) }
