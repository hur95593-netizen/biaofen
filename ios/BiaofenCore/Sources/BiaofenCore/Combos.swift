// Combos.swift — 牌型识别、压牌比较、收墩判定(1:1 移植自 server/game/combos.go)
import Foundation

/// (花色,点数) 键 —— 同键的两张即一对
func cardKey(_ c: Card) -> String { "\(c.suit)-\(c.rank)" }

public enum ComboType: String, Sendable {
    case single, pair, tractor
}

/// Combo 识别结果
public struct Combo: Sendable, Equatable {
    public let type: ComboType
    public let length: Int
    public let group: String
    public let top: Int
    public let pairs: Int
}

/// 一组阶梯位是否连成一条拖拉机(排序后相邻差恰为 1,无重复)
func isConsecutive(_ positions: [Int]) -> Bool {
    let s = positions.sorted()
    guard s.count > 1 else { return true }
    for i in 1..<s.count where s[i] - s[i - 1] != 1 {
        return false
    }
    return true
}

/// 按牌的出现顺序收集 (suit,rank) 键 → 代表牌与张数(保持插入顺序)
struct KeyEntry {
    var card: Card
    var count: Int
}

func orderedByKey(_ cards: [Card]) -> [KeyEntry] {
    var idx: [String: Int] = [:]
    var out: [KeyEntry] = []
    for c in cards {
        let k = cardKey(c)
        if let i = idx[k] {
            out[i].count += 1
        } else {
            idx[k] = out.count
            out.append(KeyEntry(card: c, count: 1))
        }
    }
    return out
}

/// 识别牌型;非法/混合组返回 nil
public func detectCombo(_ cards: [Card], _ trumpSuit: String) -> Combo? {
    guard !cards.isEmpty else { return nil }
    let group = cardGroup(cards[0], trumpSuit)
    for c in cards where cardGroup(c, trumpSuit) != group {
        return nil // 单一牌型必须同组
    }

    if cards.count == 1 {
        return Combo(type: .single, length: 1, group: group, top: strength(cards[0], trumpSuit), pairs: 0)
    }

    // 配对:同花色同点数,且每种恰好 2 张
    let entries = orderedByKey(cards)
    for e in entries where e.count != 2 {
        return nil
    }

    var top = 0
    for e in entries {
        top = max(top, strength(e.card, trumpSuit))
    }

    if cards.count == 2 {
        return Combo(type: .pair, length: 2, group: group, top: top, pairs: 0)
    }

    // 拖拉机:各对子按「相邻刻度」连续,且同 lane(同花色/同孤岛)
    let ranks = entries.map { tractorRank($0.card, trumpSuit) }
    let lane = ranks[0].lane
    for r in ranks where r.lane != lane {
        return nil
    }
    // 主 A 有两个可选阶梯位(接 2 或接 K),同 lane 最多一对 A → 试每种取位能否连成
    var fixed: [Int] = []
    var flex: TRank?
    for r in ranks {
        if r.alt != 0 && flex == nil {
            flex = r
        } else {
            fixed.append(r.pos)
        }
    }
    let linked: Bool
    if let f = flex {
        linked = isConsecutive(fixed + [f.pos]) || isConsecutive(fixed + [f.alt])
    } else {
        linked = isConsecutive(fixed)
    }
    if !linked { return nil }
    return Combo(type: .tractor, length: cards.count, group: group, top: top, pairs: ranks.count)
}

/// b 能否压过 a(a 为当前最大,b 为新出)。两者需同型同长。
public func beats(_ b: Combo?, _ a: Combo?) -> Bool {
    guard let b, let a else { return false }
    if b.type != a.type || b.length != a.length { return false }
    if a.group == "TRUMP" {
        return b.group == "TRUMP" && b.top > a.top
    }
    if b.group == "TRUMP" {
        return true // 用主牌杀边牌
    }
    if b.group == a.group {
        return b.top > a.top // 同花色比大小
    }
    return false // 不同边花色:垫牌,压不过
}

/// 一墩收谁。plays 第 0 个为首攻,返回获胜下标。
public func resolveTrick(_ plays: [[Card]], _ trumpSuit: String) -> Int {
    var winner = 0
    var best = detectCombo(plays[0], trumpSuit)
    for i in 1..<plays.count {
        let c = detectCombo(plays[i], trumpSuit)
        if beats(c, best) {
            winner = i
            best = c
        }
    }
    return winner
}
