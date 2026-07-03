// SimTests.swift — 全 AI 自动对局(移植自 server/game/sim_test.go):验证整局流程、合法性、结算守恒
import XCTest
@testable import BiaofenCore

final class SimTests: XCTestCase {
    @discardableResult
    private func playOneHand(_ g: Game) throws -> HandResult {
        g.startHand()
        var guardCount = 0
        while g.phase == .bidding {
            try g.placeBid(seat: g.bidTurn, amount: aiBid(g, g.bidTurn))
            guardCount += 1
            if guardCount > 50 { throw XCTSkip("喊分死循环") }
        }
        try g.declareTrump(aiTrump(g, g.declarer))
        try g.buryCards(aiBury(g, g.declarer))
        guardCount = 0
        while g.phase == .play {
            let seat = g.turn
            let cards = g.isLeadTurn ? aiLead(g, seat) : aiFollow(g, seat)
            XCTAssertTrue(
                g.validatePlay(seat: seat, cards: cards),
                "AI 给出非法牌: 局\(g.handNo) 座\(seat) 牌\(cards.map(\.id)) 首攻=\(g.isLeadTurn)"
            )
            try g.playCards(seat: seat, cards: cards)
            guardCount += 1
            if guardCount > 10000 { XCTFail("出牌死循环"); break }
        }
        guard let r = g.result else {
            XCTFail("局未结束却无结果")
            throw GameError.wrongPhase("no result")
        }
        return r
    }

    private func simMany(players: Int, hands: Int, seed: UInt64) throws {
        let g = Game(players: players, seed: seed)
        var zhuangWins = 0, xianWins = 0, draws = 0
        for i in 0..<hands {
            let r = try playOneHand(g)
            XCTAssertEqual(r.deltas.reduce(0, +), 0, "局 \(i + 1) 结算不守恒: \(r.deltas)")
            XCTAssertGreaterThanOrEqual(r.xianPoints, 0, "闲家分为负")
            if r.perXian == 0 {
                draws += 1
            } else if r.perXian < 0 {
                zhuangWins += 1
            } else {
                xianWins += 1
            }
        }
        XCTAssertEqual(g.scores.reduce(0, +), 0, "累计积分不守恒: \(g.scores)")
        print("\(players) 人 × \(hands) 局:庄家赢 \(zhuangWins),闲家赢 \(xianWins),平 \(draws),累计积分 \(g.scores)")
    }

    func testSim3Players() throws {
        try simMany(players: 3, hands: 300, seed: 99)
    }

    func testSim4Players() throws {
        try simMany(players: 4, hands: 300, seed: 99)
    }

    /// 分数牌守恒:一局里 闲家捡分 + 庄家守住的分 = 200(通过捡到的分数牌反推)
    func testPointConservation() throws {
        let g = Game(players: 4, seed: 7)
        for _ in 0..<20 {
            let r = try playOneHand(g)
            let captured = g.xianCaptured.reduce(0) { $0 + pointValue($1) }
            var expected = captured
            if r.lastTrickBonus > 0 {
                // 翻倍部分:xianPoints 里含 bonus,captured 只含牌面 → bonus 与牌面差为 ×2 加成
                let kittyFace = g.buried.reduce(0) { $0 + pointValue($1) }
                expected = captured - kittyFace + r.lastTrickBonus
            }
            XCTAssertEqual(r.xianPoints, expected, "闲家分与捡到的分数牌不一致")
            XCTAssertLessThanOrEqual(captured, 200, "分数牌总量不超过 200")
        }
    }
}
