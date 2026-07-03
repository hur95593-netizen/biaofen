// GameEngine.swift — 「飙分」一桌/一局流程状态机(1:1 移植自 server/game/game.go)
// 阶段 Phase: bidding → declare → kitty → play → done
import Foundation

/// 底分:喊 100 → 100,每多 10 分多 100
public func baseStake(_ contract: Int) -> Int { (contract - 90) * 10 }

func removeCards(_ hand: [Card], _ cards: [Card]) -> [Card] {
    let ids = Set(cards.map(\.id))
    return hand.filter { !ids.contains($0.id) }
}

public struct Play: Sendable {
    public let seat: Int
    public let cards: [Card]
    public let combo: Combo?
}

public struct Trick: Sendable {
    public let plays: [Play]
    public let winnerSeat: Int
    public let points: Int
}

public struct HandResult: Sendable {
    public let declarer: Int
    public let contract: Int
    public let line: Int
    public let xianPoints: Int
    public let lastTrickBonus: Int
    public let label: String
    public let perXian: Int
    public let stake: Int
    public let deltas: [Int]
    public let scores: [Int]
}

public enum Phase: String, Sendable {
    case idle, bidding, declare, kitty, play, done
}

public enum GameError: Error, LocalizedError {
    case wrongPhase(String)
    case notYourTurn
    case badBid
    case badBury(String)
    case illegalPlay

    public var errorDescription: String? {
        switch self {
        case .wrongPhase(let s): return "阶段不对:\(s)"
        case .notYourTurn: return "未轮到该家"
        case .badBid: return "喊分必须是 100~200、10 的倍数、且高于当前最高"
        case .badBury(let s): return "扣底不合法:\(s)"
        case .illegalPlay: return "出牌不合法"
        }
    }
}

/// 一桌的完整状态。空值约定:declarer/highBidder = -1,highBid/contract = 0,trumpSuit = ""。
public final class Game {
    public let players: Int
    var rng: SeededRNG
    public private(set) var scores: [Int] // 累计积分

    public private(set) var firstBidder: Int // 起喊人(第一局随机,之后按胜负轮转)
    public private(set) var handNo = 0

    public private(set) var hands: [[Card]] = []
    public private(set) var kitty: [Card] = []
    public private(set) var kittySize = 0
    public private(set) var buried: [Card] = []

    public private(set) var trumpSuit = ""
    public private(set) var declarer = -1
    public private(set) var contract = 0
    public private(set) var phase: Phase = .idle
    public private(set) var highBid = 0
    public private(set) var highBidder = -1
    public private(set) var passed: [Bool] = []
    public private(set) var bidTurn = 0

    public private(set) var xianPoints = 0
    public private(set) var xianCaptured: [Card] = [] // 闲家捡到的分数牌
    public private(set) var lastTrickBonus = 0

    public private(set) var tricks: [Trick] = []
    public private(set) var trickPlays: [Play] = []
    public private(set) var leadCombo: Combo?
    public private(set) var leader = -1
    public private(set) var turn = -1
    public private(set) var result: HandResult?

    public init(players: Int, seed: UInt64) {
        self.players = players
        var r = SeededRNG(seed: seed)
        self.firstBidder = Int.random(in: 0..<players, using: &r) // 第一局随机起喊
        self.rng = r
        self.scores = Array(repeating: 0, count: players)
    }

    public func startHand() {
        handNo += 1
        let d = deal(shuffle(buildDeck(), &rng), players: players)
        hands = d.hands
        kitty = d.kitty
        kittySize = d.kittySize
        buried = []
        trumpSuit = ""
        declarer = -1
        contract = 0
        phase = .bidding
        highBid = 0
        highBidder = -1
        passed = Array(repeating: false, count: players)
        bidTurn = firstBidder
        xianPoints = 0
        xianCaptured = []
        lastTrickBonus = 0
        tricks = []
        trickPlays = []
        leadCombo = nil
        leader = -1
        turn = -1
        result = nil
    }

    // MARK: - 喊分(多轮拍卖:往上加价,到 200 或其余都放弃才结束)

    public func nextBidLevel() -> Int {
        if highBid == 0 { return 100 }
        if highBid + 10 > 200 { return 200 }
        return highBid + 10
    }

    /// amount = 0 表示"不喊"(放弃);否则必须是 100~200、10 的倍数、高于当前最高。
    public func placeBid(seat: Int, amount: Int) throws {
        guard phase == .bidding else { throw GameError.wrongPhase("非喊分阶段") }
        guard seat == bidTurn else { throw GameError.notYourTurn }
        if amount != 0 {
            let floor = highBid == 0 ? 90 : highBid
            guard amount % 10 == 0, amount >= 100, amount <= 200, amount > floor else {
                throw GameError.badBid
            }
            highBid = amount
            highBidder = seat
        } else {
            passed[seat] = true // 放弃后本局不再参与
        }
        if highBid == 200 {
            finishBidding() // 到顶,直接坐庄
            return
        }
        // 找下一个有资格的人:还没放弃、且不是当前最高者(最高者无须再加价)
        for i in 1...players {
            let c = (seat + i) % players
            if !passed[c] && c != highBidder {
                bidTurn = c
                return
            }
        }
        finishBidding() // 其余都已放弃
    }

    private func finishBidding() {
        declarer = highBidder != -1 ? highBidder : firstBidder
        contract = highBid != 0 ? highBid : 100
        phase = .declare
    }

    // MARK: - 亮主 + 扣底

    public func declareTrump(_ suit: String) throws {
        guard phase == .declare else { throw GameError.wrongPhase("非亮主阶段") }
        trumpSuit = suit
        hands[declarer].append(contentsOf: kitty) // 庄家拿底牌
        phase = .kitty
    }

    public func buryCards(_ cards: [Card]) throws {
        guard phase == .kitty else { throw GameError.wrongPhase("非扣底阶段") }
        guard cards.count == kittySize else { throw GameError.badBury("扣底数量不对") }
        guard isSubMultiset(cards, hands[declarer]) else { throw GameError.badBury("扣底的牌不在手中") }
        hands[declarer] = removeCards(hands[declarer], cards)
        buried = cards
        phase = .play
        leader = declarer // 庄家首攻
        turn = declarer
        trickPlays = []
        leadCombo = nil
    }

    // MARK: - 出牌

    public var isLeadTurn: Bool { trickPlays.isEmpty }

    public func validatePlay(seat: Int, cards: [Card]) -> Bool {
        guard phase == .play, seat == turn, !cards.isEmpty else { return false }
        guard isSubMultiset(cards, hands[seat]) else { return false }
        if isLeadTurn {
            return detectCombo(cards, trumpSuit) != nil // 首攻:单/对/拖拉机
        }
        guard let lead = leadCombo else { return false }
        return isLegalFollow(hand: hands[seat], lead: lead, play: cards, trumpSuit: trumpSuit)
    }

    public func playCards(seat: Int, cards: [Card]) throws {
        guard validatePlay(seat: seat, cards: cards) else { throw GameError.illegalPlay }
        if isLeadTurn {
            leadCombo = detectCombo(cards, trumpSuit)
        }
        hands[seat] = removeCards(hands[seat], cards)
        trickPlays.append(Play(seat: seat, cards: cards, combo: detectCombo(cards, trumpSuit)))
        if trickPlays.count == players {
            settleTrick()
        } else {
            turn = (turn + 1) % players
        }
    }

    private func settleTrick() {
        let widx = resolveTrick(trickPlays.map(\.cards), trumpSuit)
        let win = trickPlays[widx]
        var pts = 0
        for p in trickPlays {
            for c in p.cards {
                pts += pointValue(c)
            }
        }
        let isXian = win.seat != declarer
        if isXian {
            xianPoints += pts
            for p in trickPlays {
                for c in p.cards where pointValue(c) > 0 {
                    xianCaptured.append(c) // 记录捡到的分牌
                }
            }
        }

        let handsEmpty = hands.allSatisfy(\.isEmpty)
        if handsEmpty, isXian, let combo = win.combo, combo.group == "TRUMP" {
            // 底牌捡分:最后一墩闲家用主牌赢 → 翻底捡分;对子/拖拉机 ×2,单牌 ×1
            var kp = 0
            for c in buried {
                kp += pointValue(c)
            }
            let mult = combo.type == .single ? 1 : 2
            lastTrickBonus = kp * mult
            xianPoints += lastTrickBonus
            for c in buried where pointValue(c) > 0 {
                xianCaptured.append(c)
            }
        }

        tricks.append(Trick(plays: trickPlays, winnerSeat: win.seat, points: pts))
        trickPlays = []
        leader = win.seat
        turn = win.seat
        leadCombo = nil
        if handsEmpty {
            finishHand()
        }
    }

    // MARK: - 结算

    private func finishHand() {
        let L = 200 - contract
        let x = xianPoints
        let perXian: Int // 闲家视角的底数(正=闲家赢,负=闲家输)
        let label: String
        switch x {
        case 0:
            perXian = -2
            label = "庄家光头"
        case ..<L:
            perXian = -1
            label = "庄家赢"
        case L:
            perXian = 0
            label = "平手"
        default:
            perXian = 1 + (x - L - 1) / 30
            label = "闲家赢(\(perXian)档)"
        }

        let stake = baseStake(contract)
        var deltas = Array(repeating: 0, count: players)
        var zhuang = 0
        for s in 0..<players where s != declarer {
            deltas[s] = perXian * stake
            zhuang -= perXian * stake
        }
        deltas[declarer] = zhuang
        for s in 0..<players {
            scores[s] += deltas[s]
        }

        // 下局起喊:庄家输(闲家赢)→ 庄家下家;否则庄家
        firstBidder = x > L ? (declarer + 1) % players : declarer

        result = HandResult(
            declarer: declarer, contract: contract, line: L,
            xianPoints: x, lastTrickBonus: lastTrickBonus,
            label: label, perXian: perXian, stake: stake,
            deltas: deltas, scores: scores
        )
        phase = .done
    }
}
