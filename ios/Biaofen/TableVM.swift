// TableVM.swift — 牌桌界面的数据/操作协议:单机(本地引擎)与联机(服务器视图)共用同一套 UI
import Foundation
import Observation
import BiaofenCore

@MainActor
protocol TableVM: AnyObject, Observable {
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
