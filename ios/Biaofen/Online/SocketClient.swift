// SocketClient.swift — URLSessionWebSocketTask 薄封装(回调统一切回主线程)
import Foundation

@MainActor
final class SocketClient {
    private var task: URLSessionWebSocketTask?
    private let url: URL

    var onData: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    init(url: URL) {
        self.url = url
    }

    func connect() {
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === t else { return } // 旧连接的回调丢弃
                switch result {
                case .failure(let err):
                    self.task = nil
                    self.onClose?(err.localizedDescription)
                case .success(let msg):
                    switch msg {
                    case .data(let d):
                        self.onData?(d)
                    case .string(let s):
                        self.onData?(Data(s.utf8))
                    @unknown default:
                        break
                    }
                    self.receive(on: t)
                }
            }
        }
    }

    func send(_ msg: OutMsg) {
        guard let task, let data = try? JSONEncoder().encode(msg) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    /// 把用户输入的地址规范化成 ws(s)://…/ws
    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("https://") {
            s = "wss://" + s.dropFirst("https://".count)
        } else if s.hasPrefix("http://") {
            s = "ws://" + s.dropFirst("http://".count)
        } else if !s.hasPrefix("ws://") && !s.hasPrefix("wss://") {
            // 裸域名/IP:本地地址走 ws,其余默认 wss(云端都有 HTTPS)
            let local = s.hasPrefix("127.") || s.hasPrefix("192.168.") || s.hasPrefix("10.")
                || s.hasPrefix("localhost") || s.hasPrefix("172.")
            s = (local ? "ws://" : "wss://") + s
        }
        guard var comps = URLComponents(string: s) else { return nil }
        if comps.path.isEmpty || comps.path == "/" {
            comps.path = "/ws"
        }
        return comps.url
    }
}
