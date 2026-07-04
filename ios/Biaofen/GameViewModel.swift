// GameViewModel.swift — 界面状态:包一层规则引擎,驱动 AI 节奏、收集人类操作
import SwiftUI
import Observation
import BiaofenCore

@MainActor
@Observable
final class GameViewModel: TableVM {
    let humanSeat = 0
    let supportsHint = true
    let roomBadge: String? = nil
    let toast: String? = nil

    func seatIsBot(_ seat: Int) -> Bool { seat != humanSeat }
    func seatConnected(_ seat: Int) -> Bool { true }

    private var engine: Game?
    private var aiTask: Task<Void, Never>?

    // ---- 引擎状态快照(每次操作后从 engine 刷新,驱动 SwiftUI 更新)----
    var inGame = false
    var players = 4
    var phase: Phase = .idle
    var handNo = 0
    var myHand: [Card] = []
    var handCounts: [Int] = []
    var trumpSuit = ""
    var contract = 0
    var declarer = -1
    var highBid = 0
    var highBidder = -1
    var passed: [Bool] = []
    var bidTurn = -1
    var turn = -1
    var isLeadTurn = true
    var kittySize = 0
    var xianPoints = 0
    var scores: [Int] = []
    var trickPlays: [Play] = []
    var result: HandResult?

    // ---- 纯界面状态 ----
    var selected: Set<String> = []
    var displayTrick: Trick? // 一墩打完后短暂停留展示
    var autopilot = false // 调试:人类座位也由 AI 代打

    // MARK: - 开局 / 刷新

    func startGame(players: Int) {
        aiTask?.cancel()
        self.players = players
        engine = Game(players: players, seed: UInt64.random(in: 1...UInt64.max))
        inGame = true
        newHand()
    }

    func backToMenu() {
        aiTask?.cancel()
        engine = nil
        inGame = false
        phase = .idle
        result = nil
        selected = []
        displayTrick = nil
    }

    func newHand() {
        guard let e = engine else { return }
        selected = []
        displayTrick = nil
        e.startHand()
        refresh()
        driveAI()
    }

    private func refresh() {
        guard let e = engine else { return }
        phase = e.phase
        handNo = e.handNo
        myHand = sortHand(e.hands.indices.contains(humanSeat) ? e.hands[humanSeat] : [], e.trumpSuit)
        handCounts = e.hands.map(\.count)
        trumpSuit = e.trumpSuit
        contract = e.contract
        declarer = e.declarer
        highBid = e.highBid
        highBidder = e.highBidder
        passed = e.passed
        bidTurn = e.bidTurn
        turn = e.turn
        isLeadTurn = e.isLeadTurn
        kittySize = e.kittySize
        xianPoints = e.xianPoints
        scores = e.scores
        trickPlays = e.trickPlays
        result = e.result
    }

    // MARK: - AI 驱动(带出牌节奏)

    private func driveAI() {
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            await self?.runAILoop()
        }
    }

    private func runAILoop() async {
        guard let e = engine else { return }
        while !Task.isCancelled {
            switch e.phase {
            case .bidding:
                if e.bidTurn == humanSeat && !autopilot { return }
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return }
                let amt = aiBid(e, e.bidTurn)
                try? e.placeBid(seat: e.bidTurn, amount: amt)
                if amt > 0 { SoundPlayer.shared.play("bid") }
                refresh()
            case .declare:
                if e.declarer == humanSeat && !autopilot { return }
                try? await Task.sleep(for: .milliseconds(700))
                if Task.isCancelled { return }
                try? e.declareTrump(aiTrump(e, e.declarer))
                SoundPlayer.shared.play("trump")
                refresh()
            case .kitty:
                if e.declarer == humanSeat && !autopilot { return }
                try? await Task.sleep(for: .milliseconds(800))
                if Task.isCancelled { return }
                try? e.buryCards(aiBury(e, e.declarer))
                refresh()
            case .play:
                if e.turn == humanSeat && !autopilot { return }
                try? await Task.sleep(for: .milliseconds(650))
                if Task.isCancelled { return }
                let seat = e.turn
                let cards = e.isLeadTurn ? aiLead(e, seat) : aiFollow(e, seat)
                let before = e.tricks.count
                try? e.playCards(seat: seat, cards: cards)
                SoundPlayer.shared.play("play")
                refresh()
                await pauseIfTrickDone(before)
            case .idle, .done:
                return
            }
        }
    }

    /// 一墩刚打完 → 把整墩摆出来停一拍再收走
    private func pauseIfTrickDone(_ tricksBefore: Int) async {
        guard let e = engine, e.tricks.count > tricksBefore, let last = e.tricks.last else { return }
        SoundPlayer.shared.play("trick")
        if let r = e.result {
            SoundPlayer.shared.play(r.deltas[humanSeat] > 0 ? "win" : (r.deltas[humanSeat] < 0 ? "lose" : "trick"))
            SoundPlayer.shared.haptic(.medium)
        }
        displayTrick = last
        try? await Task.sleep(for: .milliseconds(1250))
        displayTrick = nil
        refresh()
    }

    // MARK: - 人类操作

    func humanBid(_ amount: Int) {
        guard let e = engine, e.phase == .bidding, e.bidTurn == humanSeat else { return }
        try? e.placeBid(seat: humanSeat, amount: amount)
        if amount > 0 { SoundPlayer.shared.play("bid") }
        refresh()
        driveAI()
    }

    func humanDeclare(_ suit: String) {
        guard let e = engine, e.phase == .declare, e.declarer == humanSeat else { return }
        try? e.declareTrump(suit)
        SoundPlayer.shared.play("trump")
        refresh()
        driveAI()
    }

    func humanBury() {
        guard let e = engine, e.phase == .kitty, e.declarer == humanSeat else { return }
        let cards = myHand.filter { selected.contains($0.id) }
        guard cards.count == e.kittySize else { return }
        try? e.buryCards(cards)
        selected = []
        refresh()
        driveAI()
    }

    func humanPlay() {
        guard let e = engine, e.phase == .play, e.turn == humanSeat else { return }
        let cards = myHand.filter { selected.contains($0.id) }
        guard e.validatePlay(seat: humanSeat, cards: cards) else { return }
        let before = e.tricks.count
        try? e.playCards(seat: humanSeat, cards: cards)
        SoundPlayer.shared.play("play")
        SoundPlayer.shared.haptic(.medium)
        selected = []
        refresh()
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            await self?.pauseIfTrickDone(before)
            await self?.runAILoop()
        }
    }

    func hint() {
        guard let e = engine, e.phase == .play, e.turn == humanSeat else { return }
        let cards = e.isLeadTurn ? aiLead(e, humanSeat) : aiFollow(e, humanSeat)
        selected = Set(cards.map(\.id))
    }

    func toggleSelect(_ card: Card) {
        guard canSelectCards else { return }
        if selected.contains(card.id) {
            selected.remove(card.id)
        } else {
            selected.insert(card.id)
        }
        SoundPlayer.shared.play("select")
        SoundPlayer.shared.haptic(.light)
    }

    // MARK: - 界面辅助

    var canSelectCards: Bool {
        (phase == .play && turn == humanSeat) || (phase == .kitty && declarer == humanSeat)
    }

    var canPlaySelection: Bool {
        guard let e = engine, phase == .play, turn == humanSeat else { return false }
        let cards = myHand.filter { selected.contains($0.id) }
        return !cards.isEmpty && e.validatePlay(seat: humanSeat, cards: cards)
    }

    var nextBidLevel: Int {
        engine?.nextBidLevel() ?? 100
    }

    func playerName(_ seat: Int) -> String {
        if seat == humanSeat { return "你" }
        let rel = (seat - humanSeat + players) % players
        if players == 4 {
            return ["", "下家", "对家", "上家"][rel]
        }
        return ["", "下家", "上家"][rel]
    }

    /// 座位相对位置:0=底(自己) 1=右 2=顶(4人)/左(3人) 3=左
    func relPosition(_ seat: Int) -> Int {
        (seat - humanSeat + players) % players
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
            if displayTrick != nil { return "" }
            return turn == humanSeat ? (isLeadTurn ? "你首攻" : "轮到你出牌") : "等待 \(playerName(turn)) 出牌…"
        case .done:
            return "本局结束"
        }
    }
}

// MARK: - 花色显示

enum SuitStyle {
    static func symbol(_ suit: String) -> String {
        switch suit {
        case "S": return "♠"
        case "H": return "♥"
        case "D": return "♦"
        case "C": return "♣"
        default: return "?"
        }
    }

    static func isRed(_ suit: String) -> Bool {
        suit == "H" || suit == "D"
    }

    static func rankText(_ rank: Int) -> String {
        switch rank {
        case 11: return "J"
        case 12: return "Q"
        case 13: return "K"
        case 14: return "A"
        default: return "\(rank)"
        }
    }
}
