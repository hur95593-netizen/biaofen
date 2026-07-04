// Cards.swift — 「飙分」规则引擎(1:1 移植自 server/game/cards.go,规则见 飙分-规则.md)
import Foundation

public let SMALL_JOKER = 16
public let BIG_JOKER = 17
public let SUITS = ["S", "H", "D", "C"] // ♠ ♥ ♦ ♣

/// Card 与前端/后端字段一致(id 格式 "S-5-0"),便于日后联机互通。
public struct Card: Hashable, Sendable, Identifiable, Codable {
    public let suit: String
    public let rank: Int
    public let copy: Int

    public init(suit: String, rank: Int, copy: Int = 0) {
        self.suit = suit
        self.rank = rank
        self.copy = copy
    }

    public var id: String { "\(suit)-\(rank)-\(copy)" }
    public var isJoker: Bool { suit == "JOKER" }
}

/// 分数牌:5=5,10=10,K=10
public func pointValue(_ c: Card) -> Int {
    if c.rank == 5 { return 5 }
    if c.rank == 10 || c.rank == 13 { return 10 }
    return 0
}

/// 一副 54 张(52 + 大小王),两副共 108
public func buildDeck() -> [Card] {
    var cards: [Card] = []
    cards.reserveCapacity(108)
    for copy in 0..<2 {
        for s in SUITS {
            for r in 2...14 {
                cards.append(Card(suit: s, rank: r, copy: copy))
            }
        }
        cards.append(Card(suit: "JOKER", rank: SMALL_JOKER, copy: copy))
        cards.append(Card(suit: "JOKER", rank: BIG_JOKER, copy: copy))
    }
    return cards
}

/// 常主:大小王、所有 3、所有 2;再加主花色全部 → 主牌
public func isTrump(_ c: Card, _ trumpSuit: String) -> Bool {
    if c.isJoker { return true }
    if c.rank == 3 || c.rank == 2 { return true }
    return c.suit == trumpSuit
}

/// 分组:"TRUMP" 或 边花色字母("H"/"D"/"C"/"S")
public func cardGroup(_ c: Card, _ trumpSuit: String) -> String {
    isTrump(c, trumpSuit) ? "TRUMP" : c.suit
}

/// 组内「比大小」刻度(越大越强)——决定谁压谁。与「拖拉机相邻」是两套规则(见 tractorRank)。
/// 主牌:大王200 > 小王199 > 主3 198 > 副3 197 > 主2 196 > 副2 195 > 主A 194 …… 主4 184。
public func strength(_ c: Card, _ trumpSuit: String) -> Int {
    if cardGroup(c, trumpSuit) != "TRUMP" { return c.rank } // 边牌:4..14
    if c.rank == BIG_JOKER { return 200 }
    if c.rank == SMALL_JOKER { return 199 }
    let mainSuit = c.suit == trumpSuit
    switch c.rank {
    case 3: return mainSuit ? 198 : 197 // 主3 > 副3
    case 2: return mainSuit ? 196 : 195 // 主2 > 副2(且所有3 > 所有2)
    default: return c.rank + 180 // 主花色 4..14(A) → 184..194(均 < 副2 195)
    }
}

/// TRank 「拖拉机相邻」刻度——只管连不连,与比大小分开。
/// 同 lane(同花色/同孤岛)且 pos 差 1 才相连。alt=0 表示无备选位;
/// 主 A「两头都连」→ pos:1 兼 alt:14(接 2 也接 K)。王自成孤岛(16/17 相邻)。
public struct TRank: Sendable {
    public let lane: String
    public let pos: Int
    public let alt: Int

    public init(lane: String, pos: Int, alt: Int = 0) {
        self.lane = lane
        self.pos = pos
        self.alt = alt
    }
}

public func tractorRank(_ c: Card, _ trumpSuit: String) -> TRank {
    if c.isJoker { return TRank(lane: "JOKER", pos: c.rank) }
    if isTrump(c, trumpSuit) {
        if c.rank == 14 { return TRank(lane: "T-\(c.suit)", pos: 1, alt: 14) } // 主A(A 必为主花色)
        return TRank(lane: "T-\(c.suit)", pos: c.rank) // 主3=3、主2=2、…、主K=13
    }
    return TRank(lane: c.suit, pos: c.rank) // 边牌 ace-high 4..14
}

public func shuffle(_ cards: [Card], _ rng: inout some RandomNumberGenerator) -> [Card] {
    var a = cards
    var i = a.count - 1
    while i > 0 {
        let j = Int.random(in: 0...i, using: &rng)
        a.swapAt(i, j)
        i -= 1
    }
    return a
}

public struct DealResult: Sendable {
    public let hands: [[Card]]
    public let kitty: [Card]
    public let kittySize: Int
    public let perHand: Int
}

/// 发牌。players: 3 或 4。4 人 → 每人 25、底牌 8;3 人 → 每人 33、底牌 9。
public func deal(_ cards: [Card], players: Int) -> DealResult {
    let kittySize = players == 4 ? 8 : 9
    let perHand = (cards.count - kittySize) / players
    var hands: [[Card]] = []
    var i = 0
    for _ in 0..<players {
        hands.append(Array(cards[i..<(i + perHand)]))
        i += perHand
    }
    return DealResult(hands: hands, kitty: Array(cards[i...]), kittySize: kittySize, perHand: perHand)
}

/// 边花色展示顺序:按手牌里实际存在的边花色动态交错(黑红穿插,不易看错)。
/// 多的那种颜色排外侧、少的穿插;整门被扣掉/打光后自动重排。
public func sideSuitOrder(_ present: Set<String>) -> [String] {
    let blacks = ["S", "C"].filter { present.contains($0) }
    let reds = ["H", "D"].filter { present.contains($0) }
    let (longer, shorter) = reds.count > blacks.count ? (reds, blacks) : (blacks, reds)
    var out: [String] = []
    for i in 0..<longer.count {
        out.append(longer[i])
        if i < shorter.count {
            out.append(shorter[i])
        }
    }
    return out
}

/// 整理手牌(展示用):主牌在前,组内从大到小;相同的牌相邻(对子不被拆)
public func sortHand(_ hand: [Card], _ trumpSuit: String) -> [Card] {
    var present: Set<String> = []
    for c in hand where cardGroup(c, trumpSuit) != "TRUMP" {
        present.insert(c.suit)
    }
    var groupOrder = ["TRUMP": 0]
    for (i, s) in sideSuitOrder(present).enumerated() {
        groupOrder[s] = i + 1
    }
    let suitOrder = ["S": 0, "H": 1, "D": 2, "C": 3, "JOKER": 4]
    return hand.stableSorted { a, b in
        let ga = groupOrder[cardGroup(a, trumpSuit)] ?? 9
        let gb = groupOrder[cardGroup(b, trumpSuit)] ?? 9
        if ga != gb { return ga < gb }
        let sa = strength(a, trumpSuit), sb = strength(b, trumpSuit)
        if sa != sb { return sa > sb }
        if a.suit != b.suit { return (suitOrder[a.suit] ?? 9) < (suitOrder[b.suit] ?? 9) }
        if a.rank != b.rank { return a.rank > b.rank }
        return a.copy < b.copy
    }
}

extension Array {
    /// 稳定排序(Go sort.SliceStable 的对应物;Swift 的 sorted 不保证稳定)
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated()
            .sorted { a, b in
                if areInIncreasingOrder(a.element, b.element) { return true }
                if areInIncreasingOrder(b.element, a.element) { return false }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}

/// 可播种随机数(SplitMix64):同 seed 同牌局,测试可复现
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
