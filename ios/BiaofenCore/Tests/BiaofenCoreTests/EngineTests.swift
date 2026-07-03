// EngineTests.swift — 规则内核测试(移植自 server/game/engine_test.go)
import XCTest
@testable import BiaofenCore

func C(_ suit: String, _ rank: Int, _ copy: Int = 0) -> Card {
    Card(suit: suit, rank: rank, copy: copy)
}

func J(_ big: Bool, _ copy: Int = 0) -> Card {
    Card(suit: "JOKER", rank: big ? BIG_JOKER : SMALL_JOKER, copy: copy)
}

let T = "S" // 主花色 ♠

final class EngineTests: XCTestCase {
    func testDeck() {
        let deck = buildDeck()
        XCTAssertEqual(deck.count, 108, "两副共 108 张")
        XCTAssertEqual(deck.filter(\.isJoker).count, 4, "共 4 张王")
    }

    func testDeal() {
        let d4 = deal(buildDeck(), players: 4)
        XCTAssertEqual(d4.hands.count, 4)
        XCTAssertEqual(d4.kitty.count, 8, "4人:底牌8")
        for h in d4.hands {
            XCTAssertEqual(h.count, 25, "4人每人25")
        }
        let d3 = deal(buildDeck(), players: 3)
        XCTAssertEqual(d3.hands.count, 3)
        XCTAssertEqual(d3.kitty.count, 9, "3人:底牌9")
        for h in d3.hands {
            XCTAssertEqual(h.count, 33, "3人每人33")
        }
    }

    func testPermanentTrumps() {
        XCTAssertTrue(isTrump(C("S", 5), T), "♠5 是主(主花色)")
        XCTAssertTrue(isTrump(C("H", 3), T), "♥3 是主(常主 3)")
        XCTAssertTrue(isTrump(C("H", 2), T), "♥2 是主(常主 2)")
        XCTAssertFalse(isTrump(C("H", 7), T), "♥7 不是主(7 普通)")
        XCTAssertTrue(isTrump(J(true), T), "大王是主")
    }

    func testStrength() {
        let order = [J(true), J(false), C("S", 3), C("S", 2), C("S", 14), C("S", 7), C("S", 4)]
        for i in 1..<order.count {
            XCTAssertGreaterThan(
                strength(order[i - 1], T), strength(order[i], T),
                "主牌顺序第 \(i) 处未递减"
            )
        }
        XCTAssertGreaterThan(strength(C("S", 3), T), strength(C("H", 3), T), "主3 > 副3")
        XCTAssertGreaterThan(strength(C("S", 2), T), strength(C("H", 2), T), "主2 > 副2")
        XCTAssertGreaterThan(strength(C("H", 3), T), strength(C("S", 2), T), "所有 3 > 所有 2(副3 > 主2)")
        // 单张 主3 > 主K(♥主:♥3 压 ♥K)
        let k3 = detectCombo([C("H", 3)], "H")
        let kk = detectCombo([C("H", 13)], "H")
        XCTAssertTrue(beats(k3, kk), "♥主时 ♥3 压 ♥K")
        XCTAssertEqual(strength(C("D", 3), T), strength(C("C", 3), T), "副3 大小相同(♦3 = ♣3)")
        XCTAssertEqual(strength(C("H", 7), T), 7, "♥7 边牌强度 = 7")
    }

    func testDetectCombo() {
        let cases: [(name: String, cards: [Card], trump: String, want: ComboType?)] = [
            ("单张", [C("S", 5)], T, .single),
            ("对子 ♠5♠5", [C("S", 5, 0), C("S", 5, 1)], T, .pair),
            ("♥3+♦3 不是对子(副主跨花色)", [C("H", 3), C("D", 3)], T, nil),
            ("5566 是拖拉机", [C("H", 5, 0), C("H", 5, 1), C("H", 6, 0), C("H", 6, 1)], T, .tractor),
            ("6677 是拖拉机(7 普通)", [C("H", 6, 0), C("H", 6, 1), C("H", 7, 0), C("H", 7, 1)], T, .tractor),
            ("6688 不是拖拉机", [C("H", 6, 0), C("H", 6, 1), C("H", 8, 0), C("H", 8, 1)], T, nil),
            ("大王大王+小王小王 是拖拉机", [J(true, 0), J(true, 1), J(false, 0), J(false, 1)], T, .tractor),
            ("主3主3+小王小王 不是拖拉机(王孤岛)", [C("S", 3, 0), C("S", 3, 1), J(false, 0), J(false, 1)], T, nil),
            ("♥3♥3+♦3♦3 不是拖拉机(副主同级)", [C("H", 3, 0), C("H", 3, 1), C("D", 3, 0), C("D", 3, 1)], T, nil),
            ("♠3♠3+♥3♥3 不是拖拉机", [C("S", 3, 0), C("S", 3, 1), C("H", 3, 0), C("H", 3, 1)], T, nil),
            ("♠3♠3+♠2♠2 是拖拉机(3 与 2 相邻)", [C("S", 3, 0), C("S", 3, 1), C("S", 2, 0), C("S", 2, 1)], T, .tractor),
            ("♥3♥3+♥2♥2 是拖拉机(♥ 主)", [C("H", 3, 0), C("H", 3, 1), C("H", 2, 0), C("H", 2, 1)], "H", .tractor),
            ("♥3♥3+♥4♥4 是拖拉机(自然 3-4)", [C("H", 3, 0), C("H", 3, 1), C("H", 4, 0), C("H", 4, 1)], "H", .tractor),
            ("♥A♥A+♥2♥2 是拖拉机(主A 接 2)", [C("H", 14, 0), C("H", 14, 1), C("H", 2, 0), C("H", 2, 1)], "H", .tractor),
            ("♥A♥A+♥K♥K 是拖拉机(主A 也接 K)", [C("H", 14, 0), C("H", 14, 1), C("H", 13, 0), C("H", 13, 1)], "H", .tractor),
            ("♥K♥K+♥A♥A+♥2♥2 不是拖拉机(A 不桥接)",
             [C("H", 13, 0), C("H", 13, 1), C("H", 14, 0), C("H", 14, 1), C("H", 2, 0), C("H", 2, 1)], "H", nil),
            ("♥3♥3+♦2♦2 不是拖拉机(跨花色)", [C("H", 3, 0), C("H", 3, 1), C("D", 2, 0), C("D", 2, 1)], "H", nil),
        ]
        for tc in cases {
            let got = detectCombo(tc.cards, tc.trump)
            if let want = tc.want {
                XCTAssertEqual(got?.type, want, "\(tc.name): 应为 \(want), got \(String(describing: got))")
            } else {
                XCTAssertNil(got, "\(tc.name): 应为 nil, got \(String(describing: got))")
            }
        }
    }

    func testBeatsAndTrick() {
        let a = detectCombo([C("H", 9, 0), C("H", 9, 1)], T)
        let b = detectCombo([C("S", 4, 0), C("S", 4, 1)], T)
        XCTAssertTrue(beats(b, a), "主牌对子杀边牌对子")
        let b2 = detectCombo([C("H", 11, 0), C("H", 11, 1)], T)
        XCTAssertTrue(beats(b2, a), "同花色大对压小对")
        let b3 = detectCombo([C("D", 13, 0), C("D", 13, 1)], T)
        XCTAssertFalse(beats(b3, a), "不同边花色压不过")
        let w = resolveTrick([[C("H", 9)], [C("S", 4)], [C("H", 14)]], T)
        XCTAssertEqual(w, 1, "收墩:♠4 杀 → 下标1")
    }
}
