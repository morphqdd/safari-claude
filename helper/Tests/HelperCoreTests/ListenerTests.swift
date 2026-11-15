import Testing
import Foundation
@testable import HelperCore

@Suite struct ListenerTests {
    @Test func tcpListenerEchoes() async throws {
        let queue = DispatchQueue(label: "test.listener")
        let listener = try Listener.tcp(port: 0)
        var keep: [WSConnection] = []
        listener.onConnection = { conn in
            keep.append(conn)
            conn.onText = { [unowned conn] t in conn.send(t) }
        }
        listener.start(queue: queue)
        #expect(listener.boundPort != 0)

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(listener.boundPort)/")!)
        task.resume()
        try await task.send(.string("ping-text"))
        let msg = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { g in
            g.addTask { try await task.receive() }
            g.addTask { try await Task.sleep(for: .seconds(2)); throw CancellationError() }
            let m = try await g.next()!
            g.cancelAll()
            return m
        }
        guard case .string(let s) = msg else { Issue.record("not text"); return }
        #expect(s == "ping-text")
        task.cancel(with: .normalClosure, reason: nil)
        _ = keep
    }

    @Test func plainHttpGets400() async throws {
        let queue = DispatchQueue(label: "test.listener2")
        let listener = try Listener.tcp(port: 0)
        listener.start(queue: queue)
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(listener.boundPort)/")!)
        _ = data
        #expect((resp as? HTTPURLResponse)?.statusCode == 400)
    }
}
