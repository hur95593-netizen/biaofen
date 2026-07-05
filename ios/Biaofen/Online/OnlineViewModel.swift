// OnlineViewModel.swift — 联机对局:状态全部来自服务器视图,本地只做展示、合法性预校验和发指令
import SwiftUI
import Observation
import BiaofenCore

@MainActor
@Observable
final class OnlineViewModel: TableVM {
    enum Stage {
        case setup       // 输入昵称/服务器,选择创建或加入
        case connecting
        case lobby       // 已入房,等人/等开局
        case playing
    }

    var stage: Stage = .setup
    var errorText: String?
    var toast: String?

    // 配置(持久化)
    var nickname: String {
        didSet { UserDefaults.standard.set(nickname, forKey: "online.nickname") }
    }
    var serverInput: String {
        didSet { UserDefaults.standard.set(serverInput, forKey: "online.server") }
    }
    var joinCode = ""

    // 房间/连接
    private var socket: SocketClient?
    private var state: RoomState?
    private(set) var roomCode = ""
    private var token = ""
    private var leaving = false
    private var reconnectAttempt = 0
    private var prevTricksPlayed = 0
    private var wasMyTurn = false
    private var lastHandNo = -1
    private var lastKittyHand = -1
    private var displayTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    // 演示托管(--online-demo):自动建房/开局/出牌
    var demoMode = false
    private var demoSentStart = false
    private var demoLastKey = ""

    init() {
        nickname = UserDefaults.standard.string(forKey: "online.nickname") ?? "玩家"
        serverInput = UserDefaults.standard.string(forKey: "online.server") ?? "127.0.0.1:8124"
    }

    // MARK: - TableVM(从服务器视图映射)

    var humanSeat: Int { state?.mySeat ?? 0 }
    var players: Int { state?.players ?? 4 }
    var phase: Phase {
        guard let p = state?.phase, !p.isEmpty else { return .idle }
        return Phase(rawValue: p) ?? .idle
    }
    var handNo: Int { state?.handNo ?? 0 }
    var myHand: [Card] { sortHand(state?.hand ?? [], trumpSuit) }
    var handCounts: [Int] { state?.counts ?? Array(repeating: 0, count: players) }
    var trumpSuit: String { state?.trumpSuit ?? "" }
    var contract: Int { state?.contract ?? 0 }
    var declarer: Int { state?.declarer ?? -1 }
    var highBid: Int { state?.highBid ?? 0 }
    var highBidder: Int { state?.highBidder ?? -1 }
    var passed: [Bool] { state?.passed ?? Array(repeating: false, count: players) }
    var bidTurn: Int { state?.bidTurn ?? -1 }
    var turn: Int { state?.turn ?? -1 }
    var kittySize: Int { state?.kittySize ?? 0 }
    var xianPoints: Int { state?.xianPoints ?? 0 }
    var scores: [Int] { state?.scores ?? Array(repeating: 0, count: players) }
    var trickPlays: [Play] { state?.trickPlays ?? [] }
    var result: HandResult? { resultHold ? nil : state?.result }
    var nextBidLevel: Int { state?.nextBidLevel ?? 100 }
    var supportsHint: Bool { true }
    var roomBadge: String? { roomCode.isEmpty ? nil : "房号 \(roomCode)" }
    var kittyIDs: Set<String> { Set(state?.kittyIds ?? []) }
    var buriedCards: [Card] { state?.buried ?? [] }
    private var resultHold = false // 最后一墩先亮牌,结算面板延后弹出

    var displayTrick: Trick?
    var selected: Set<String> = []

    var isHost: Bool { state?.hostSeat == humanSeat }

    func seatTaken(_ seat: Int) -> Bool {
        guard let seats = state?.seats, seats.indices.contains(seat) else { return false }
        return seats[seat].taken
    }

    func hostSeatIs(_ seat: Int) -> Bool {
        state?.hostSeat == seat && seatTaken(seat)
    }

    func playerName(_ seat: Int) -> String {
        if seat == humanSeat { return "你" }
        if let seats = state?.seats, seats.indices.contains(seat), seats[seat].taken {
            return seats[seat].name
        }
        return "座位\(seat + 1)"
    }

    func relPosition(_ seat: Int) -> Int {
        (seat - humanSeat + players) % players
    }

    func seatIsBot(_ seat: Int) -> Bool {
        guard let seats = state?.seats, seats.indices.contains(seat) else { return false }
        return seats[seat].bot
    }

    func seatConnected(_ seat: Int) -> Bool {
        guard let seats = state?.seats, seats.indices.contains(seat) else { return true }
        return seats[seat].connected
    }

    var canSelectCards: Bool {
        (phase == .play && turn == humanSeat) || (phase == .kitty && declarer == humanSeat)
    }

    /// 本地预校验(核心逻辑复用 BiaofenCore),避免每次点按都请求服务器
    var canPlaySelection: Bool {
        guard phase == .play, turn == humanSeat else { return false }
        let cards = myHand.filter { selected.contains($0.id) }
        guard !cards.isEmpty else { return false }
        if trickPlays.isEmpty {
            if detectCombo(cards, trumpSuit) != nil { return true }
            // 甩牌:客户端没有完整记牌信息,多张主牌先放行,由服务器裁决(非法会 toast)
            return cards.count >= 2 && cards.allSatisfy { isTrump($0, trumpSuit) }
        }
        guard let lead = trickPlays.first?.combo else { return false }
        return isLegalFollow(hand: myHand, lead: lead, play: cards, trumpSuit: trumpSuit)
    }

    var statusText: String {
        switch phase {
        case .idle:
            return ""
        case .bidding:
            let base = highBid == 0 ? "还没人喊分" : "\(playerName(highBidder)) 喊到 \(highBid)"
            return bidTurn == humanSeat ? "轮到你喊分 · \(base)" : "\(playerName(bidTurn)) 考虑中… · \(base)"
        case .declare:
            return declarer == humanSeat ? "你坐庄,请选主花色" : "\(playerName(declarer)) 坐庄,亮主中…"
        case .kitty:
            return declarer == humanSeat ? "请选 \(kittySize) 张牌扣底" : "\(playerName(declarer)) 扣底中…"
        case .play:
            return turn == humanSeat ? (trickPlays.isEmpty ? "你首攻" : "轮到你出牌") : "等待 \(playerName(turn)) 出牌…"
        case .done:
            return "本局结束"
        }
    }

    // MARK: - 连接 / 房间

    func createRoom(players: Int) {
        open { [weak self] in
            guard let self else { return }
            self.socket?.send(OutMsg(type: "create", players: players, name: self.nickname))
        }
    }

    func joinRoom() {
        let code = joinCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else {
            showError("请输入房间码")
            return
        }
        open { [weak self] in
            guard let self else { return }
            self.socket?.send(OutMsg(type: "join", name: self.nickname, room: code))
        }
    }

    private func open(onOpen: @escaping () -> Void) {
        guard let url = SocketClient.normalize(serverInput) else {
            showError("服务器地址无效")
            return
        }
        leaving = false
        errorText = nil
        stage = .connecting
        let s = SocketClient(url: url)
        socket = s
        s.onData = { [weak self] data in self?.handleData(data) }
        s.onClose = { [weak self] reason in self?.handleClose(reason) }
        s.connect()
        // WebSocket 无显式 open 回调:直接发首条消息,失败会走 onClose
        onOpen()
    }

    func startGame() {
        socket?.send(OutMsg(type: "start"))
    }

    func leaveRoom() {
        leaving = true
        displayTask?.cancel()
        socket?.close()
        socket = nil
        state = nil
        roomCode = ""
        token = ""
        selected = []
        displayTrick = nil
        resultHold = false
        prevTricksPlayed = 0
        stage = .setup
    }

    // MARK: - TableVM 操作 → 发消息

    func humanBid(_ amount: Int) {
        socket?.send(OutMsg(type: "bid", amount: amount))
    }

    func humanDeclare(_ suit: String) {
        socket?.send(OutMsg(type: "trump", suit: suit))
    }

    func humanBury() {
        let ids = myHand.filter { selected.contains($0.id) }.map(\.id)
        guard ids.count == kittySize else { return }
        socket?.send(OutMsg(type: "bury", ids: ids))
        selected = []
    }

    func humanPlay() {
        guard canPlaySelection else { return }
        let ids = myHand.filter { selected.contains($0.id) }.map(\.id)
        socket?.send(OutMsg(type: "play", ids: ids))
        selected = []
    }

    /// 联机提示:用本视角可见信息(手牌 + 当前墩)给建议;没有全量记牌,首攻按保守 boss 判定
    func hint() {
        guard phase == .play, turn == humanSeat else { return }
        let cards = trickPlays.isEmpty
            ? suggestLead(hand: myHand, trump: trumpSuit)
            : suggestFollow(hand: myHand, plays: trickPlays, declarer: declarer,
                            mySeat: humanSeat, players: players, trump: trumpSuit)
        selected = Set(cards.map(\.id))
    }

    func newHand() {
        socket?.send(OutMsg(type: "next"))
    }

    func backToMenu() {
        leaveRoom()
    }

    func toggleSelect(_ card: Card) {
        setSelect(card, !selected.contains(card.id))
    }

    func setSelect(_ card: Card, _ on: Bool) {
        guard canSelectCards, selected.contains(card.id) != on else { return }
        if on {
            selected.insert(card.id)
        } else {
            selected.remove(card.id)
        }
        SoundPlayer.shared.play("select")
        SoundPlayer.shared.haptic(.light)
    }

    // MARK: - 收消息

    private func handleData(_ data: Data) {
        guard let msg = ServerMessage.decode(data) else { return }
        switch msg {
        case .joined(let j):
            roomCode = j.room
            token = j.token
            reconnectAttempt = 0
            UserDefaults.standard.set(j.token, forKey: "online.token.\(j.room)")
        case .state(let s):
            applyState(s)
        case .event(let e):
            handleEvent(e)
        case .error(let msg):
            // 入房失败(房间不存在/已开局/已满)→ 回设置页;局中错误 → toast
            if state == nil {
                socket?.close()
                socket = nil
                stage = .setup
                showError(msg)
            } else {
                showToast(msg)
            }
        }
    }

    private func applyState(_ s: RoomState) {
        let prevPlays = state?.trickPlays?.count ?? 0
        if (s.trickPlays?.count ?? 0) > prevPlays {
            SoundPlayer.shared.play("play")
        }
        if state?.result == nil, s.result != nil {
            // 终局:先把最后一墩亮 2 秒,再弹结算面板(面板里翻底牌)
            resultHold = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.0))
                guard let self else { return }
                self.resultHold = false
                if let r = self.state?.result, r.deltas.indices.contains(self.humanSeat) {
                    let d = r.deltas[self.humanSeat]
                    SoundPlayer.shared.play(d > 0 ? "win" : (d < 0 ? "lose" : "trick"))
                    SoundPlayer.shared.haptic(.medium)
                }
            }
        }
        let newTricks = s.tricksPlayed ?? 0
        if newTricks > prevTricksPlayed, (s.trickPlays ?? []).isEmpty, let last = s.lastTrick {
            // 一墩刚收走:整墩留在桌上(带赢家标记),下一圈有人出牌的状态到达时才清掉
            SoundPlayer.shared.play("trick")
            displayTrick = last
        } else if !(s.trickPlays ?? []).isEmpty {
            displayTrick = nil
        }
        prevTricksPlayed = newTricks
        // 轮到你出牌:提示音
        let mine = s.phase == "play" && s.turn == s.mySeat
        if mine && !wasMyTurn && newTricks > 0 {
            SoundPlayer.shared.play("yourturn")
        }
        wasMyTurn = mine
        // 新一局发牌音 + 自己坐庄拿底牌时默认选中底牌
        if let hn = s.handNo, hn != lastHandNo, s.started {
            lastHandNo = hn
            SoundPlayer.shared.play("deal")
        }
        if s.phase == "kitty", s.declarer == s.mySeat, lastKittyHand != (s.handNo ?? -1) {
            lastKittyHand = s.handNo ?? -1
            selected = Set(s.kittyIds ?? [])
        }
        state = s
        stage = s.started ? .playing : .lobby
        if demoMode {
            demoAct(s)
        }
    }

    private func handleEvent(_ e: EventMsg) {
        let name = playerName(e.seat)
        switch e.kind {
        case "joined":
            showToast("\(name) 加入了")
        case "left":
            showToast("\(name) 离开了")
        case "disconnected":
            showToast("\(name) 掉线,AI 托管中")
        case "reconnected":
            showToast("\(name) 重连回来了")
        case "bid":
            if let amt = e.data?.intValue, amt > 0 {
                SoundPlayer.shared.play("bid")
                showToast("\(name) 喊 \(amt)")
            } else {
                showToast("\(name) 不喊")
            }
        case "declarerSet":
            showToast("\(name) 坐庄")
        case "trump":
            SoundPlayer.shared.play("trump")
            showToast("\(name) 亮主 \(SuitStyle.symbol(e.data?.stringValue ?? ""))")
        case "buried":
            showToast("庄家已扣底")
        case "trick":
            if let pts = e.data?.intValue, pts > 0 {
                showToast("\(name) 收墩 +\(pts) 分")
            }
        case "result":
            if let label = e.data?.stringValue {
                showToast(label)
            }
        default:
            break
        }
    }

    private func handleClose(_ reason: String?) {
        socket = nil
        if leaving { return }
        if state != nil, !token.isEmpty, reconnectAttempt < 5 {
            // 局中断线:带 token 自动重连回原座位
            reconnectAttempt += 1
            let attempt = reconnectAttempt
            showToast("连接断开,第 \(attempt) 次重连…")
            let code = roomCode
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(attempt) * 1.5))
                guard let self, !self.leaving, self.socket == nil else { return }
                self.open { [weak self] in
                    guard let self else { return }
                    self.socket?.send(OutMsg(type: "join", name: self.nickname, room: code, token: self.token))
                }
                self.stage = self.state?.started == true ? .playing : .lobby
            }
        } else {
            leaveRoom()
            showError(reason.map { "连接失败:\($0)" } ?? "连接已断开")
        }
    }

    private func showError(_ msg: String) {
        errorText = msg
    }

    private func showToast(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            self?.toast = nil
        }
    }

    // MARK: - 演示托管(端到端自测用,不在正常 UI 暴露)

    func startDemo(server: String) {
        demoMode = true
        serverInput = server
        nickname = "模拟器"
        createRoom(players: 4)
    }

    private func demoAct(_ s: RoomState) {
        if !s.started {
            if !demoSentStart, s.hostSeat == s.mySeat {
                demoSentStart = true
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(800))
                    self?.startGame()
                }
            }
            return
        }
        let phase = s.phase ?? ""
        let me = s.mySeat
        let myTurn = (phase == "bidding" && s.bidTurn == me)
            || ((phase == "declare" || phase == "kitty") && s.declarer == me)
            || (phase == "play" && s.turn == me)
        guard myTurn else { return }
        let key = "\(s.handNo ?? 0)|\(phase)|\(s.hand?.count ?? 0)|\(s.trickPlays?.count ?? 0)|\(s.highBid ?? 0)"
        guard key != demoLastKey else { return }
        demoLastKey = key

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            let hand = s.hand ?? []
            let trump = s.trumpSuit ?? ""
            switch phase {
            case "bidding":
                self.humanBid(0) // 演示:一律不喊,让 AI 坐庄
            case "declare":
                var counts: [String: Int] = [:]
                for c in hand where c.suit != "JOKER" {
                    counts[c.suit, default: 0] += 1
                }
                let suit = SUITS.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? "S"
                self.humanDeclare(suit)
            case "kitty":
                if let ids = s.kittyIds, ids.count == s.kittySize {
                    self.socket?.send(OutMsg(type: "bury", ids: ids)) // 原样扣回底牌,必然合法
                }
            case "play":
                let tp = s.trickPlays ?? []
                if tp.isEmpty {
                    if let c = hand.min(by: { strength($0, trump) < strength($1, trump) }) {
                        self.socket?.send(OutMsg(type: "play", ids: [c.id]))
                    }
                } else if let lead = tp.first?.combo {
                    let cards = buildFollow(hand, lead, trump)
                    self.socket?.send(OutMsg(type: "play", ids: cards.map(\.id)))
                }
            default:
                break
            }
        }
    }
}
