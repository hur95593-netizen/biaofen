// FollowTests.swift — 跟牌 + 跟大 测试(移植自 server/game/follow_test.go;主花色 ♠)
import XCTest
@testable import BiaofenCore

final class FollowTests: XCTestCase {
    private func lf(_ hand: [Card], _ lead: Combo?, _ play: [Card]) -> Bool {
        guard let lead else { return false }
        return isLegalFollow(hand: hand, lead: lead, play: play, trumpSuit: T)
    }

    func testFollowPair() {
        // 有对必须跟对
        let hand = [C("H", 9, 0), C("H", 9, 1), C("H", 10, 0), C("H", 11, 0)]
        let lead = detectCombo([C("H", 4, 0), C("H", 4, 1)], T)
        XCTAssertTrue(lf(hand, lead, [C("H", 9, 0), C("H", 9, 1)]), "跟对子合法")
        XCTAssertFalse(lf(hand, lead, [C("H", 9, 0), C("H", 10, 0)]), "有对却拆成两单 → 非法")
        // 边牌无对,任意两张单
        let hand2 = [C("H", 9, 0), C("H", 10, 0), C("H", 11, 0), C("H", 13, 0)]
        XCTAssertTrue(lf(hand2, lead, [C("H", 9, 0), C("H", 11, 0)]), "边牌随便两张单")
    }

    func testFollowPairTrumpTopTwo() {
        // 主牌无对,跟大(最大两张)
        let hand = [J(false, 0), C("S", 13, 0), C("S", 5, 0)]
        let lead = detectCombo([C("S", 6, 0), C("S", 6, 1)], T)
        XCTAssertTrue(lf(hand, lead, [J(false, 0), C("S", 13, 0)]), "出最大两张(小王+♠K)合法")
        XCTAssertFalse(lf(hand, lead, [C("S", 13, 0), C("S", 5, 0)]), "藏起小王 → 非法")
        XCTAssertFalse(lf(hand, lead, [J(false, 0), C("S", 5, 0)]), "藏起♠K → 非法")
        // 主牌有对,必须跟对(不是跟大单)
        let hand2 = [C("S", 5, 0), C("S", 5, 1), J(false, 0)]
        XCTAssertTrue(lf(hand2, lead, [C("S", 5, 0), C("S", 5, 1)]), "跟对 ♠5♠5 合法")
        XCTAssertFalse(lf(hand2, lead, [J(false, 0), C("S", 5, 0)]), "有对却出 小王+♠5 → 非法")
    }

    func testFollowTractorTopSingles() {
        // 拖拉机:跟大单牌(飙分里 主3 很大)
        let hand = [C("S", 12, 0), C("S", 12, 1), J(false, 0), C("S", 5, 0), C("S", 3, 0)]
        let lead = detectCombo([C("S", 14, 0), C("S", 14, 1), C("S", 13, 0), C("S", 13, 1)], T)
        XCTAssertTrue(
            lf(hand, lead, [C("S", 12, 0), C("S", 12, 1), J(false, 0), C("S", 3, 0)]),
            "♠Q♠Q + 小王 + ♠3(最大两单)合法"
        )
        XCTAssertFalse(
            lf(hand, lead, [C("S", 12, 0), C("S", 12, 1), J(false, 0), C("S", 5, 0)]),
            "漏了更大的♠3 → 非法"
        )
        XCTAssertFalse(
            lf(hand, lead, [C("S", 12, 0), J(false, 0), C("S", 3, 0), C("S", 5, 0)]),
            "不出对子(拆 ♠Q)→ 非法"
        )
    }

    func testFollowTractorMustTractor() {
        // 有等长拖拉机必须跟拖拉机
        let hand = [C("H", 7, 0), C("H", 7, 1), C("H", 8, 0), C("H", 8, 1), C("H", 11, 0), C("H", 11, 1)]
        let lead = detectCombo([C("H", 5, 0), C("H", 5, 1), C("H", 6, 0), C("H", 6, 1)], T)
        XCTAssertTrue(
            lf(hand, lead, [C("H", 7, 0), C("H", 7, 1), C("H", 8, 0), C("H", 8, 1)]),
            "跟 ♥7788 拖拉机合法"
        )
        XCTAssertFalse(
            lf(hand, lead, [C("H", 7, 0), C("H", 7, 1), C("H", 11, 0), C("H", 11, 1)]),
            "有拖拉机却出 ♥77+♥JJ → 非法"
        )
    }

    func testFollowSuit() {
        // 有该花色必须跟,没有可垫/杀
        let lead = detectCombo([C("H", 4, 0), C("H", 4, 1)], T)
        let noHearts = [C("S", 4, 0), C("S", 4, 1), C("D", 9, 0)]
        XCTAssertTrue(lf(noHearts, lead, [C("S", 4, 0), C("S", 4, 1)]), "没♥:用主♠对子杀,合法")
        XCTAssertTrue(lf(noHearts, lead, [C("S", 4, 0), C("D", 9, 0)]), "没♥:垫两张杂牌,合法")
        let hasHearts = [C("H", 9, 0), C("H", 10, 0), C("S", 4, 0), C("S", 4, 1)]
        XCTAssertFalse(lf(hasHearts, lead, [C("S", 4, 0), C("S", 4, 1)]), "有♥却用主牌 → 非法")
        XCTAssertTrue(lf(hasHearts, lead, [C("H", 9, 0), C("H", 10, 0)]), "有♥就跟两张♥,合法")
    }
}
