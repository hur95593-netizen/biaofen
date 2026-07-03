// ServerMessages.swift — 与 Go 服务器的消息 DTO(字段与 server/client.go、server/view.go 对齐)
import Foundation
import BiaofenCore

// MARK: - 客户端 → 服务器

struct OutMsg: Encodable {
    var type: String // create|join|start|bid|trump|bury|play|next
    var players: Int?
    var name: String?
    var room: String?
    var token: String?
    var amount: Int?
    var suit: String?
    var ids: [String]?
}

// MARK: - 服务器 → 客户端

struct JoinedMsg: Decodable {
    var room: String
    var seat: Int
    var token: String
    var players: Int
}

struct SeatDTO: Decodable {
    var taken: Bool
    var bot: Bool
    var name: String
    var connected: Bool
}

/// 按座位打码的对局视图(view.go 的 View;game == nil 时后半部分字段为 null)
struct RoomState: Decodable {
    var room: String
    var players: Int
    var started: Bool
    var seats: [SeatDTO]
    var hostSeat: Int
    var mySeat: Int

    var phase: String?
    var handNo: Int?
    var scores: [Int]?

    var bidTurn: Int?
    var highBid: Int?
    var highBidder: Int?
    var passed: [Bool]?
    var nextBidLevel: Int?

    var declarer: Int?
    var contract: Int?
    var trumpSuit: String?
    var kittySize: Int?
    var kittyIds: [String]?

    var turn: Int?
    var leader: Int?
    var hand: [Card]?
    var counts: [Int]?
    var trickPlays: [Play]?
    var lastTrick: Trick?
    var tricksPlayed: Int?
    var xianPoints: Int?
    var xianCaptured: [Card]?

    var result: HandResult?
    var buried: [Card]?
}

struct EventMsg: Decodable {
    var kind: String
    var seat: Int
    var data: JSONValue?
}

/// 宽松 JSON 值(event.data 按 kind 可能是数字/字符串/空)
enum JSONValue: Decodable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else {
            self = .null
        }
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

enum ServerMessage {
    case joined(JoinedMsg)
    case state(RoomState)
    case event(EventMsg)
    case error(String)

    static func decode(_ data: Data) -> ServerMessage? {
        struct Head: Decodable { var type: String }
        struct Err: Decodable { var msg: String }
        let dec = JSONDecoder()
        guard let head = try? dec.decode(Head.self, from: data) else { return nil }
        switch head.type {
        case "joined":
            return (try? dec.decode(JoinedMsg.self, from: data)).map { .joined($0) }
        case "state":
            return (try? dec.decode(RoomState.self, from: data)).map { .state($0) }
        case "event":
            return (try? dec.decode(EventMsg.self, from: data)).map { .event($0) }
        case "error":
            return (try? dec.decode(Err.self, from: data)).map { .error($0.msg) }
        default:
            return nil
        }
    }
}
