// AI.swift — 电脑玩家(记牌 + 抢分/封锁 + 喂分/躲分),1:1 移植自 server/game/ai.go
import Foundation

func ascS(_ cards: [Card], _ t: String) -> [Card] {
    cards.stableSorted { strength($0, t) < strength($1, t) }
}

func descS(_ cards: [Card], _ t: String) -> [Card] {
    cards.stableSorted { strength($0, t) > strength($1, t) }
}

func sideOf(_ hand: [Card], _ t: String) -> [Card] {
    hand.filter { cardGroup($0, t) != "TRUMP" }
}

func trumpOf(_ hand: [Card], _ t: String) -> [Card] {
    hand.filter { cardGroup($0, t) == "TRUMP" }
}

/// 按 (花色,点数) 分组,保持出现顺序
func groupByKeyOrdered(_ cardsG: [Card]) -> [[Card]] {
    var idx: [String: Int] = [:]
    var out: [[Card]] = []
    for c in cardsG {
        let k = cardKey(c)
        if let i = idx[k] {
            out[i].append(c)
        } else {
            idx[k] = out.count
            out.append([c])
        }
    }
    return out
}

func pairList(_ cardsG: [Card]) -> [[Card]] {
    groupByKeyOrdered(cardsG).filter { $0.count >= 2 }.map { Array($0.prefix(2)) }
}

func singleList(_ cardsG: [Card]) -> [Card] {
    groupByKeyOrdered(cardsG).filter { $0.count == 1 }.map { $0[0] }
}

/// 在对子列表里找一条长度 k、且最大那对 strength > minTop 的拖拉机(按自然阶梯,同 lane)。
/// 取满足条件里"最小"(top 最低)的一条;找不到返回 nil。与 combos/follow 的相邻判定一致。
func findLadderRun(_ pairs: [[Card]], _ k: Int, _ t: String, _ minTop: Int) -> [[Card]]? {
    struct Entry {
        let p: [Card]
        var pos: Int
        let alt: Int
        let s: Int
    }
    var laneOrder: [String] = []
    var byLane: [String: [Entry]] = [:]
    for p in pairs {
        let r = tractorRank(p[0], t)
        if byLane[r.lane] == nil { laneOrder.append(r.lane) }
        byLane[r.lane, default: []].append(Entry(p: p, pos: r.pos, alt: r.alt, s: strength(p[0], t)))
    }
    var found: [[Card]]?
    var foundTop = Int.max
    for lane in laneOrder {
        let list = byLane[lane]!
        // 主 A 有两个可选阶梯位(同 lane 最多一对 A)→ 分别试 pos 与 alt
        var flex: Entry?
        var fixed: [Entry] = []
        for e in list {
            if e.alt != 0 && flex == nil {
                flex = e
            } else {
                fixed.append(e)
            }
        }
        var variants: [[Entry]]
        if let f = flex {
            var altE = f
            altE.pos = f.alt
            variants = [fixed + [f], fixed + [altE]]
        } else {
            variants = [fixed]
        }
        for variant in variants {
            let arr = variant.stableSorted { $0.pos < $1.pos }
            guard arr.count >= k, k >= 1 else { continue }
            for i in 0...(arr.count - k) {
                var ok = true
                for j in 1..<k where arr[i + j].pos - arr[i + j - 1].pos != 1 {
                    ok = false
                    break
                }
                if !ok { continue }
                var top = 0
                for x in arr[i..<(i + k)] {
                    top = max(top, x.s)
                }
                if top <= minTop { continue }
                if found == nil || top < foundTop {
                    found = arr[i..<(i + k)].map(\.p)
                    foundTop = top
                }
            }
        }
    }
    return found
}

/// 已经亮出的所有牌(用于记牌)
func seenCards(_ g: Game) -> [Card] {
    var out: [Card] = []
    for tr in g.tricks {
        for p in tr.plays {
            out.append(contentsOf: p.cards)
        }
    }
    for p in g.trickPlays {
        out.append(contentsOf: p.cards)
    }
    return out
}

/// 一个组(边花色或主)的全部候选牌(每种 2 张)
func groupCandidates(_ group: String, _ t: String) -> [Card] {
    if group != "TRUMP" {
        return (4...14).map { Card(suit: group, rank: $0) }
    }
    var out = [Card(suit: "JOKER", rank: BIG_JOKER), Card(suit: "JOKER", rank: SMALL_JOKER)]
    for s in SUITS {
        out.append(Card(suit: s, rank: 3))
        out.append(Card(suit: s, rank: 2))
    }
    for r in 4...14 {
        out.append(Card(suit: t, rank: r))
    }
    return out
}

/// cand 还没露面(不在已出牌、不在我手)的张数
func remainingCopies(_ cand: Card, _ seen: [Card], _ hand: [Card]) -> Int {
    var copies = 2
    for x in seen where x.suit == cand.suit && x.rank == cand.rank { copies -= 1 }
    for x in hand where x.suit == cand.suit && x.rank == cand.rank { copies -= 1 }
    return max(copies, 0)
}

/// 组内(边花色与主牌通用)比 card 更大、还没露面的张数 —— 0 即当前最大(boss)
func unseenHigher(_ card: Card, _ seen: [Card], _ hand: [Card], _ t: String) -> Int {
    let s = strength(card, t)
    var cnt = 0
    for cand in groupCandidates(cardGroup(card, t), t) where strength(cand, t) > s {
        cnt += remainingCopies(cand, seen, hand)
    }
    return cnt
}

/// 组内比 card 更大、且对手还可能凑成一对的档位数 —— 0 即我的对子无对可压(不含主杀)
func unseenHigherPair(_ card: Card, _ seen: [Card], _ hand: [Card], _ t: String) -> Int {
    let s = strength(card, t)
    var cnt = 0
    for cand in groupCandidates(cardGroup(card, t), t) where strength(cand, t) > s {
        if remainingCopies(cand, seen, hand) == 2 { cnt += 1 }
    }
    return cnt
}

/// 对手手里(约)还剩多少主。底牌里的主看不见 → 宁可高估,多拉一轮
func othersTrumps(_ g: Game, _ seat: Int) -> Int {
    let t = g.trumpSuit
    var total = 42 // 4王 + 8张3 + 8张2 + 主花色4..A共22张
    for c in seenCards(g) where isTrump(c, t) { total -= 1 }
    for c in g.hands[seat] where isTrump(c, t) { total -= 1 }
    return total
}

// MARK: - 喊分(逐级 +10,直到超出自己的目标)

/// JS Math.round:恰好 .5 时向 +∞ 取整
func jsRound(_ x: Double) -> Int { Int(floor(x + 0.5)) }

func bidTarget(_ hand: [Card]) -> Int {
    var jok = 0, threes = 0, twos = 0
    var sc = ["S": 0, "H": 0, "D": 0, "C": 0]
    for c in hand {
        if c.suit == "JOKER" {
            jok += 1
        } else {
            if c.rank == 3 { threes += 1 } else if c.rank == 2 { twos += 1 }
            sc[c.suit, default: 0] += 1
        }
    }
    let best = SUITS.map { sc[$0] ?? 0 }.max() ?? 0
    let str = Double(jok) * 1.5 + Double(threes) * 1.2 + Double(twos) * 1.0 + Double(best) * 0.4
    // 烂牌返回 <100(弃喊),只有够强的手牌才往上喊;上限 200
    let v = 100 + 10 * jsRound(str - 13)
    return min(v, 200)
}

/// 返回喊分数;0 = 不喊
public func aiBid(_ g: Game, _ seat: Int) -> Int {
    let lv = g.nextBidLevel()
    return bidTarget(g.hands[seat]) >= lv ? lv : 0 // 愿意就加最小一档,否则放弃
}

/// 亮主:选最长花色当主
public func aiTrump(_ g: Game, _ seat: Int) -> String {
    var sc = ["S": 0, "H": 0, "D": 0, "C": 0]
    for c in g.hands[seat] where c.suit != "JOKER" {
        sc[c.suit, default: 0] += 1
    }
    var best = "S"
    for s in SUITS where (sc[s] ?? 0) > (sc[best] ?? 0) {
        best = s
    }
    return best
}

// MARK: - 扣底:扣最没用的(非主、非分、低点)

func discardScore(_ c: Card, _ t: String) -> Int {
    var s = 0
    if isTrump(c, t) { s += 1000 }
    switch c.rank {
    case 13: s += 800 // K:分牌 + 大牌,尽量留着打
    case 14: s += 500 // A:boss,别扣
    case 10: s -= 10  // 10/5:打不赢就藏进底牌护分(闲家抢不到)
    case 5: s -= 40
    default: break
    }
    if cardGroup(c, t) != "TRUMP" { s += c.rank }
    return s
}

public func aiBury(_ g: Game, _ seat: Int) -> [Card] {
    let t = g.trumpSuit
    let hand = g.hands[seat]
    let need = g.kittySize
    var discards: [Card] = []
    // 1) 优先把"短的、无分的边花色"整门扣掉做空门 → 以后那门一出就能用主牌杀
    var bySuit: [String: [Card]] = [:]
    for c in hand where cardGroup(c, t) != "TRUMP" {
        bySuit[c.suit, default: []].append(c)
    }
    let suits = SUITS.filter { !(bySuit[$0] ?? []).isEmpty }
        .stableSorted { (bySuit[$0] ?? []).count < (bySuit[$1] ?? []).count }
    for s in suits {
        let grp = bySuit[s] ?? []
        let hasBig = grp.contains { $0.rank >= 13 } // A/K 留着打;5/10 随短门扣掉反而是藏分
        if grp.count <= need - discards.count && !hasBig {
            discards.append(contentsOf: grp)
        }
    }
    // 2) 剩余名额:扣最没用的(非主、非分、低点)
    if discards.count < need {
        let ids = Set(discards.map(\.id))
        let rest = hand.filter { !ids.contains($0.id) }
            .stableSorted { discardScore($0, t) < discardScore($1, t) }
        for c in rest {
            if discards.count >= need { break }
            discards.append(c)
        }
    }
    if discards.count > need {
        discards = Array(discards.prefix(need))
    }
    return discards
}

/// 首攻:拖拉机 > 庄家控主 > boss 对子 > boss 单张 > 小牌过渡
public func aiLead(_ g: Game, _ seat: Int) -> [Card] {
    let t = g.trumpSuit
    let hand = g.hands[seat]
    let seen = seenCards(g)
    if let run = leadTractor(hand, t, seen) {
        return run // 拖拉机几乎无解,还能一手甩掉多张
    }
    if seat == g.declarer, let draw = leadDrawTrump(g, seat, seen) {
        return draw
    }
    if let p = leadBossPair(hand, t, seen) {
        return p
    }
    if let c = leadBossSingle(hand, t, seen) {
        return c
    }
    return smallLead(hand, t)
}

/// 值得首攻的拖拉机:3 对及以上直接出;2 对要求顶张已无更高对(boss)
func leadTractor(_ hand: [Card], _ t: String, _ seen: [Card]) -> [Card]? {
    let pairs = pairList(hand)
    guard pairs.count >= 2 else { return nil }
    var k = pairs.count
    while k >= 3 {
        if let run = findLadderRun(pairs, k, t, Int.min) {
            return flattenPairs(run)
        }
        k -= 1
    }
    var minTop = Int.min
    while true {
        guard let run = findLadderRun(pairs, 2, t, minTop) else { return nil }
        let top = runTopCard(run, t)
        if unseenHigherPair(top, seen, hand, t) == 0 {
            return flattenPairs(run)
        }
        minTop = strength(top, t) // 这条顶张不硬,往更高的找
    }
}

func flattenPairs(_ run: [[Card]]) -> [Card] {
    run.flatMap { $0 }
}

func runTopCard(_ run: [[Card]], _ t: String) -> Card {
    var top = run[0][0]
    for p in run where strength(p[0], t) > strength(top, t) {
        top = p[0]
    }
    return top
}

/// 庄家控主:对手还有不少主时,有 boss 就边赢边拉;主够长没 boss 就用小主换大主
func leadDrawTrump(_ g: Game, _ seat: Int, _ seen: [Card]) -> [Card]? {
    let t = g.trumpSuit
    let hand = g.hands[seat]
    let trumps = trumpOf(hand, t)
    guard !trumps.isEmpty, othersTrumps(g, seat) >= 3 else {
        return nil // 对手主差不多光了,别再浪费
    }
    let top = descS(trumps, t)[0]
    if unseenHigher(top, seen, hand, t) == 0 {
        return [top]
    }
    if trumps.count >= 6 {
        for c in ascS(trumps, t) where pointValue(c) == 0 {
            return [c]
        }
    }
    return nil
}

/// 已无更高对的对子 → 兑现;优先带分的(闲家一手捡 20)
func leadBossPair(_ hand: [Card], _ t: String, _ seen: [Card]) -> [Card]? {
    var best: [Card]?
    var bestScore = Int.min
    for p in pairList(hand) {
        let c = p[0]
        guard unseenHigherPair(c, seen, hand, t) == 0 else { continue }
        let score = pointValue(c) * 20 + strength(c, t)
        if score > bestScore {
            best = p
            bestScore = score
        }
    }
    return best
}

/// 边花色里"当前最大"的落单牌 → 兑现,优先带分的;不拆对子
func leadBossSingle(_ hand: [Card], _ t: String, _ seen: [Card]) -> [Card]? {
    var best: Card?
    var bestScore = Int.min
    for e in orderedByKey(hand) where e.count == 1 {
        let c = e.card
        if cardGroup(c, t) == "TRUMP" { continue } // 主 boss 由庄家控主逻辑处理;闲家拉主反帮庄
        guard unseenHigher(c, seen, hand, t) == 0 else { continue }
        let score = pointValue(c) * 20 + strength(c, t)
        if score > bestScore {
            best = c
            bestScore = score
        }
    }
    return best.map { [$0] }
}

/// 过渡:最小的不带分边单张 → 最小不带分边牌 → 最小边牌 → 最小不带分牌 → 最小牌
func smallLead(_ hand: [Card], _ t: String) -> [Card] {
    let side = sideOf(hand, t)
    if !side.isEmpty {
        let singlePool = singleList(side).filter { pointValue($0) == 0 }
        if !singlePool.isEmpty {
            return [ascS(singlePool, t)[0]]
        }
        let sidePool = side.filter { pointValue($0) == 0 }
        if !sidePool.isEmpty {
            return [ascS(sidePool, t)[0]]
        }
        return [ascS(side, t)[0]]
    }
    let pool = hand.filter { pointValue($0) == 0 }
    if !pool.isEmpty {
        return [ascS(pool, t)[0]]
    }
    return [ascS(hand, t)[0]]
}

/// 构造一手合法"垫牌"(默认丢最小)
public func buildFollow(_ hand: [Card], _ lead: Combo, _ t: String) -> [Card] {
    let N = lead.length
    let G = lead.group
    var handG: [Card] = []
    var other: [Card] = []
    for c in hand {
        if cardGroup(c, t) == G { handG.append(c) } else { other.append(c) }
    }
    let m = handG.count
    if m <= N {
        return handG + Array(ascS(other, t).prefix(N - m))
    }
    switch lead.type {
    case .single:
        return [ascS(handG, t)[0]]
    case .pair:
        let pairs = pairList(handG)
        if !pairs.isEmpty {
            let sorted = pairs.stableSorted { strength($0[0], t) < strength($1[0], t) }
            return sorted[0]
        }
        let singles = singleList(handG)
        if G == "TRUMP" {
            return Array(descS(singles, t).prefix(2))
        }
        return Array(ascS(singles, t).prefix(2))
    case .tractor:
        let k = N / 2
        let pairs = pairList(handG)
        let required = min(k, pairs.count)
        var chosen: [[Card]]?
        if maxTractorLen(handG, t) >= k {
            chosen = findLadderRun(pairs, k, t, Int.min)
        }
        let picked: [[Card]]
        if let chosen {
            picked = chosen
        } else {
            let lp = pairs.stableSorted { strength($0[0], t) < strength($1[0], t) }
            picked = Array(lp.prefix(required))
        }
        var cards = picked.flatMap { $0 }
        let need = N - cards.count
        if need > 0 {
            let singles = singleList(handG)
            if G == "TRUMP" {
                cards.append(contentsOf: descS(singles, t).prefix(need))
            } else {
                cards.append(contentsOf: ascS(singles, t).prefix(need))
            }
        }
        return cards
    }
}

/// 丢牌排序键:feed=喂分(先丢大分牌,其余丢小);否则躲分(先丢小杂牌,分牌最后)
func dumpKey(_ c: Card, _ t: String, _ feed: Bool) -> Int {
    let pv = pointValue(c)
    if feed {
        if pv > 0 { return -1000 - pv * 10 }
        return strength(c, t)
    }
    if pv > 0 { return 10000 + pv }
    return strength(c, t)
}

func dumpOrder(_ cards: [Card], _ t: String, _ feed: Bool) -> [Card] {
    cards.stableSorted { dumpKey($0, t, feed) < dumpKey($1, t, feed) }
}

/// 不抢时的智能垫牌:队友赢就喂分,对手赢就躲分
func chooseDump(_ hand: [Card], _ lead: Combo, _ t: String, _ feed: Bool) -> [Card] {
    let N = lead.length
    let G = lead.group
    var handG: [Card] = []
    var other: [Card] = []
    for c in hand {
        if cardGroup(c, t) == G { handG.append(c) } else { other.append(c) }
    }
    let m = handG.count
    if m <= N {
        return handG + Array(dumpOrder(other, t, feed).prefix(N - m))
    }
    switch lead.type {
    case .single:
        return [dumpOrder(handG, t, feed)[0]]
    case .pair:
        let pairs = pairList(handG)
        if !pairs.isEmpty {
            let sorted = pairs.stableSorted { dumpKey($0[0], t, feed) < dumpKey($1[0], t, feed) }
            return sorted[0]
        }
        let singles = singleList(handG)
        if G == "TRUMP" {
            return Array(descS(singles, t).prefix(2))
        }
        return Array(dumpOrder(singles, t, feed).prefix(2))
    case .tractor:
        return buildFollow(hand, lead, t) // 拖拉机较少见,退回最小垫
    }
}

/// 在 cardsG 里找压过 minTop 的、同型同长的最小组合;没有返回 nil
func findBeatingInGroup(_ cardsG: [Card], _ lead: Combo, _ minTop: Int, _ t: String) -> [Card]? {
    switch lead.type {
    case .single:
        let cand = cardsG.filter { strength($0, t) > minTop }
        if cand.isEmpty { return nil }
        return [ascS(cand, t)[0]]
    case .pair:
        let cand = pairList(cardsG).filter { strength($0[0], t) > minTop }
        if cand.isEmpty { return nil }
        let sorted = cand.stableSorted { strength($0[0], t) < strength($1[0], t) }
        return sorted[0]
    case .tractor:
        let k = lead.length / 2
        guard let run = findLadderRun(pairList(cardsG), k, t, minTop) else { return nil }
        return run.flatMap { $0 }
    }
}

/// 构造能吃住当前最大(best)的跟牌;做不到返回 nil
public func buildWinningFollow(_ hand: [Card], _ lead: Combo, _ best: Combo, _ t: String) -> [Card]? {
    let G = lead.group
    let handG = hand.filter { cardGroup($0, t) == G }
    let trumps = trumpOf(hand, t)
    if !handG.isEmpty {
        if best.group != G { return nil }
        if handG.count < lead.length { return nil }
        return findBeatingInGroup(handG, lead, best.top, t)
    }
    if G != "TRUMP" {
        if trumps.count < lead.length { return nil }
        let minTop = best.group == "TRUMP" ? best.top : -1
        return findBeatingInGroup(trumps, lead, minTop, t)
    }
    return nil
}

/// 跟牌决策
public func aiFollow(_ g: Game, _ seat: Int) -> [Card] {
    let t = g.trumpSuit
    guard let lead = g.leadCombo else { return [] }
    let hand = g.hands[seat]
    let isZhuang = seat == g.declarer

    var best = g.trickPlays[0].combo
    var bi = 0
    for i in 1..<g.trickPlays.count {
        if beats(g.trickPlays[i].combo, best) {
            best = g.trickPlays[i].combo
            bi = i
        }
    }
    let winnerIsZhuang = g.trickPlays[bi].seat == g.declarer
    var points = 0
    for p in g.trickPlays {
        for c in p.cards {
            points += pointValue(c)
        }
    }
    let isLast = g.trickPlays.count == g.players - 1

    var wantWin = false
    var win: [Card]?
    if let best {
        win = buildWinningFollow(hand, lead, best, t)
    }
    if let w = win {
        if isZhuang {
            wantWin = !winnerIsZhuang && (points > 0 || isLast) // 庄家:封锁闲家的分墩
        } else {
            wantWin = winnerIsZhuang && (points > 0 || isLast) // 闲家:只抢庄家的墩,不抢队友
        }
        // 白捡节奏:对头正赢着,而我能用"反正当前最大"的同组单张吃 → 无分也抢(赢下一手首攻权)
        if !wantWin, lead.type == .single, w.count == 1 {
            let enemyWinning = winnerIsZhuang != isZhuang
            if enemyWinning, cardGroup(w[0], t) == lead.group,
               unseenHigher(w[0], seenCards(g), hand, t) == 0 {
                wantWin = true
            }
        }
    }
    if wantWin, let win, isLegalFollow(hand: hand, lead: lead, play: win, trumpSuit: t) {
        return win
    }

    // 不抢 → 智能垫牌:队友(闲家)赢、且庄家已出牌(吃不动了)才喂分;否则躲分
    let zhuangPlayed = g.trickPlays.contains { $0.seat == g.declarer }
    let feed = !isZhuang && !winnerIsZhuang && zhuangPlayed
    let play = chooseDump(hand, lead, t, feed)
    if isLegalFollow(hand: hand, lead: lead, play: play, trumpSuit: t) {
        return play
    }
    return buildFollow(hand, lead, t)
}
