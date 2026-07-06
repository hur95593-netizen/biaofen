// TableVM.swift — 牌桌界面的数据/操作协议:单机(本地引擎)与联机(服务器视图)共用同一套 UI
import Foundation
import Observation
import BiaofenCore

/// 牌型出场特效(拖拉机开过 / 甩牌字样)
struct PlayEffect: Equatable {
    enum Kind {
        case tractor, throwCards
    }

    let id: UUID
    let kind: Kind
}

@MainActor
protocol TableVM: AnyObject, Observable {
    var playEffect: PlayEffect? { get set }
    var humanSeat: Int { get }
    var players: Int { get }
    var phase: Phase { get }
    var handNo: Int { get }
    var myHand: [Card] { get }
    var handCounts: [Int] { get }
    var trumpSuit: String { get }
    var contract: Int { get }
    var declarer: Int { get }
    var highBid: Int { get }
    var highBidder: Int { get }
    var passed: [Bool] { get }
    var bidTurn: Int { get }
    var turn: Int { get }
    var kittySize: Int { get }
    var xianPoints: Int { get }
    var scores: [Int] { get }
    var trickPlays: [Play] { get }
    var displayTrick: Trick? { get }
    var result: HandResult? { get }
    var selected: Set<String> { get }
    var statusText: String { get }
    var canPlaySelection: Bool { get }
    var nextBidLevel: Int { get }
    var supportsHint: Bool { get }
    var roomBadge: String? { get } // 联机:房间码;单机 nil
    var toast: String? { get }     // 联机:事件/错误提示;单机 nil
    var canSelectCards: Bool { get }
    var kittyIDs: Set<String> { get } // 扣底阶段(自己坐庄):哪些是底牌 → 卡面标记
    var buriedCards: [Card] { get }   // 结算时翻开的底牌(非 done 阶段为空)

    func playerName(_ seat: Int) -> String
    func relPosition(_ seat: Int) -> Int
    func seatIsBot(_ seat: Int) -> Bool
    func seatConnected(_ seat: Int) -> Bool
    func toggleSelect(_ card: Card)
    func setSelect(_ card: Card, _ on: Bool) // 滑动批量选牌用
    func humanBid(_ amount: Int)
    func humanDeclare(_ suit: String)
    func humanBury()
    func humanPlay()
    func hint()
    func backToMenu()
    func newHand()
}

extension TableVM {
    /// 出牌反馈:配音播报(单张报点、对子报"对X"、拖拉机、甩牌)+ 牌型出场特效。
    /// 跟牌垫的散牌(不成型)不播报;首攻多张不成型 = 甩牌。
    func playFeedback(cards: [Card], wasLead: Bool, trump: String) {
        guard !cards.isEmpty else { return }
        var key: String?
        var effectKind: PlayEffect.Kind?
        if let combo = detectCombo(cards, trump) {
            switch combo.type {
            case .single:
                let c = cards[0]
                key = c.isJoker ? (c.rank == BIG_JOKER ? "sbj" : "ssj") : "s\(c.rank)"
            case .pair:
                let c = cards[0]
                key = c.isJoker ? (c.rank == BIG_JOKER ? "pbj" : "psj") : "p\(c.rank)"
            case .tractor:
                key = "tractor"
                effectKind = .tractor
            case .throwLead:
                key = "throw"
                effectKind = .throwCards
            }
        } else if wasLead && cards.count >= 2 {
            key = "throw"
            effectKind = .throwCards
        }
        if let key {
            SoundPlayer.shared.announce(key)
        }
        if let effectKind {
            let fx = PlayEffect(id: UUID(), kind: effectKind)
            playEffect = fx
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1700))
                if self?.playEffect?.id == fx.id {
                    self?.playEffect = nil
                }
            }
        }
    }
}
