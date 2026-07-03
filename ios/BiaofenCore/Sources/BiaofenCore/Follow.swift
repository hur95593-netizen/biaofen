// Follow.swift — 跟牌合法性(跟牌结构 + 跟大),1:1 移植自 server/game/follow.go
// 规则见 飙分-规则.md 第 5 节:
//   首家出什么,按 拖拉机 → 对子 → 单牌 的优先级尽量凑同结构,且必须出满该组的牌;
//   跟大:被迫拆单张主牌凑数时,单张必须是最大的;副牌不跟大。
import Foundation

/// 对子数:每种(花色,点数)满 2 张算 1 对
public func pairCount(_ cards: [Card]) -> Int {
    orderedByKey(cards).reduce(0) { $0 + $1.count / 2 }
}

/// 落单牌的 strength,从大到小
func singletonStrengths(_ cards: [Card], _ trumpSuit: String) -> [Int] {
    orderedByKey(cards)
        .filter { $0.count % 2 == 1 }
        .map { strength($0.card, trumpSuit) }
        .sorted(by: >)
}

/// 一组阶梯位里的最长连续段长度
func longestRun(_ positions: [Int]) -> Int {
    let s = Array(Set(positions)).sorted()
    guard var prev = s.first else { return 0 }
    var best = 1, run = 1
    for p in s.dropFirst() {
        if p - prev == 1 { run += 1 } else { run = 1 }
        best = max(best, run)
        prev = p
    }
    return best
}

/// 最长拖拉机(连续对子)长度。按「相邻刻度」分 lane 各算,主 A 两个取位都试。
public func maxTractorLen(_ cards: [Card], _ trumpSuit: String) -> Int {
    struct LaneInfo {
        var fixed: [Int] = []
        var flexA: (pos: Int, alt: Int)?
    }
    var byLane: [String: LaneInfo] = [:]
    for e in orderedByKey(cards) where e.count >= 2 {
        let r = tractorRank(e.card, trumpSuit)
        var info = byLane[r.lane] ?? LaneInfo()
        if r.alt != 0 {
            info.flexA = (r.pos, r.alt)
        } else {
            info.fixed.append(r.pos)
        }
        byLane[r.lane] = info
    }
    var best = 0
    for (_, info) in byLane {
        if let flexA = info.flexA {
            best = max(best, longestRun(info.fixed + [flexA.pos]), longestRun(info.fixed + [flexA.alt]))
        } else {
            best = max(best, longestRun(info.fixed))
        }
    }
    return best
}

func isPairCards(_ cards: [Card]) -> Bool {
    cards.count == 2 && cards[0].suit == cards[1].suit && cards[0].rank == cards[1].rank
}

/// sub 是否为 sup 的子多重集(按牌 ID)
public func isSubMultiset(_ sub: [Card], _ sup: [Card]) -> Bool {
    var have: [String: Int] = [:]
    for c in sup { have[c.id, default: 0] += 1 }
    for c in sub {
        guard let n = have[c.id], n > 0 else { return false }
        have[c.id] = n - 1
    }
    return true
}

func sameIntMultiset(_ a: [Int], _ b: [Int]) -> Bool {
    a.count == b.count && a.sorted() == b.sorted()
}

/// 跟大:play 的落单牌必须正好是 hand 落单牌里最大的 count 张
func topSingletonsOK(_ playG: [Card], _ handG: [Card], _ count: Int, _ trumpSuit: String) -> Bool {
    var want = singletonStrengths(handG, trumpSuit)
    if want.count > count { want = Array(want.prefix(count)) }
    let got = singletonStrengths(playG, trumpSuit)
    return got.count == count && sameIntMultiset(want, got)
}

/// play 是否为对 lead 的一手合法跟牌。lead 为 detectCombo 结果。
/// 已知简化(与 Go/JS 版一致):当"自己最长拖拉机 < 首攻拖拉机长度"时,只强制"用满最大对子数",
/// 不强制把较短的拖拉机也连着出。常见的"有等长拖拉机必须跟"已强制。
public func isLegalFollow(hand: [Card], lead: Combo, play: [Card], trumpSuit: String) -> Bool {
    let N = lead.length
    guard play.count == N, isSubMultiset(play, hand) else { return false }

    let G = lead.group
    let handG = hand.filter { cardGroup($0, trumpSuit) == G }
    let playG = play.filter { cardGroup($0, trumpSuit) == G }
    let m = handG.count
    let need = min(m, N)
    guard playG.count == need else {
        return false // 必须出满该组的牌(有就得跟)
    }

    if m <= N {
        return true // 该组牌被迫全出,无取舍
    }

    // m > N:组内有取舍,按结构跟牌
    switch lead.type {
    case .single:
        return true // 任意一张
    case .pair:
        if pairCount(handG) >= 1 {
            return isPairCards(playG) // 有对必须跟对(任意对)
        }
        if G == "TRUMP" {
            return topSingletonsOK(playG, handG, 2, trumpSuit) // 主牌跟大
        }
        return true // 边牌:任意两张单
    case .tractor:
        let k = N / 2
        let required = min(k, pairCount(handG))
        guard pairCount(playG) == required else {
            return false // 必须用满最大对子数
        }
        if maxTractorLen(handG, trumpSuit) >= k && maxTractorLen(playG, trumpSuit) < k {
            return false // 有(够长)拖拉机必须跟拖拉机
        }
        let singlesNeeded = N - 2 * required
        if singlesNeeded > 0 && G == "TRUMP" {
            return topSingletonsOK(playG, handG, singlesNeeded, trumpSuit) // 单牌部分跟大
        }
        return true
    }
}
