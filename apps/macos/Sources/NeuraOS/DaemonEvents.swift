import Foundation

// One bounded wakeup slot per consumer. Changes arriving during a fetch remain
// pending, so the transition from replay to waiting cannot lose an update.
@MainActor final class EventPulse {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() {
        var continuation: AsyncStream<Void>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {continuation = $0}
        self.continuation = continuation
    }
    func signal() {continuation.yield(())}
    func finish() {continuation.finish()}
}

@MainActor final class DaemonEvents {
    private static var connections: [String: DaemonEvents] = [:]
    static func shared(endpoint: URL, dataDirectory: URL) -> DaemonEvents {
        let key = endpoint.absoluteString + "\n" + dataDirectory.path
        if let existing = connections[key] {return existing}
        let connection = DaemonEvents(endpoint: endpoint, dataDirectory: dataDirectory)
        connections[key] = connection
        return connection
    }
    struct Change: Decodable {
        let type: String
        var epoch: String?
        var state: Bool?
        var terminals: [String]?
        var browser: Bool?
    }
    let nativeId = UUID().uuidString.lowercased()
    private(set) var supported = false
    private(set) var connected = false
    private let endpoint: URL
    private let dataDirectory: URL
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var observers: [UUID: (Change) -> Void] = [:]
    private let session = URLSession(configuration: .ephemeral)

    init(endpoint: URL, dataDirectory: URL) {
        self.endpoint = endpoint
        self.dataDirectory = dataDirectory
    }
    @discardableResult func observe(_ observer: @escaping (Change) -> Void) -> UUID {
        let id = UUID(); observers[id] = observer; return id
    }
    func remove(_ id: UUID) {observers.removeValue(forKey: id)}
    func configure(features: [String]?) {
        guard features?.contains("state.stream") == true else {
            guard supported else {return}
            supported = false; connected = false
            generation = UUID()
            task?.cancel(); task = nil
            socket?.cancel(with: .goingAway, reason: nil); socket = nil
            publish(Change(type: "disconnected"))
            return
        }
        supported = true
        guard task == nil else {return}
        let current = generation
        task = Task { [weak self] in await self?.run(generation: current) }
    }
    private func publish(_ change: Change) {
        // Callbacks can remove observers while handling a deleted terminal.
        for observer in Array(observers.values) {observer(change)}
    }
    private func run(generation current: UUID) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                var url = URLComponents(url: endpoint.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false)!
                url.queryItems = [URLQueryItem(name: "nativeId", value: nativeId)]
                url.scheme = endpoint.scheme == "https" ? "wss" : "ws"
                var request = URLRequest(url: url.url!)
                let token = try String(contentsOf: dataDirectory.appendingPathComponent("daemon-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let ws = session.webSocketTask(with: request)
                ws.maximumMessageSize = 1024 * 1024
                socket = ws; ws.resume()
                // A half-open connection must not leave every consumer asleep.
                // One heartbeat covers the whole app, regardless of tab count.
                let heartbeat = Task {
                    while !Task.isCancelled {
                        do {try await Task.sleep(for: .seconds(15))} catch {return}
                        let deadline = Task {
                            do {try await Task.sleep(for: .seconds(5))} catch {return}
                            ws.cancel(with: .goingAway, reason: nil)
                        }
                        do {
                            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                ws.sendPing {error in
                                    if let error {continuation.resume(throwing: error)}
                                    else {continuation.resume()}
                                }
                            }
                        } catch {deadline.cancel(); ws.cancel(with: .goingAway, reason: nil); return}
                        deadline.cancel()
                    }
                }
                defer {heartbeat.cancel(); ws.cancel(with: .goingAway, reason: nil)}
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    guard generation == current, !Task.isCancelled else {return}
                    let change = try JSONDecoder().decode(Change.self, from: data)
                    guard change.type == "ready" || change.type == "changed" else {continue}
                    if change.type == "ready" {connected = true; attempt = 0}
                    publish(change)
                }
            } catch {
                guard generation == current, !Task.isCancelled else {return}
                connected = false
                socket?.cancel(with: .goingAway, reason: nil); socket = nil
                publish(Change(type: "disconnected"))
            }
            guard !Task.isCancelled else {break}
            attempt = min(attempt + 1, 5)
            let seconds = min(10, 0.25 * pow(2, Double(attempt))) + Double.random(in: 0...0.25)
            try? await Task.sleep(for: .seconds(seconds))
        }
    }
}

// Only failures schedule work; healthy idle consumers remain asleep.
@MainActor final class FailureRetry {
    private var task: Task<Void, Never>?
    private var attempt = 0
    private let base: Double
    init(base: Double = 0.5) {self.base = base}
    func update(failed: Bool, wake: @escaping @MainActor () -> Void) {
        guard failed else {task?.cancel(); task = nil; attempt = 0; return}
        guard task == nil else {return}
        let delay = min(30, base * pow(2, Double(attempt)))
        attempt = min(attempt + 1, 6)
        task = Task { [weak self] in
            do {try await Task.sleep(for: .seconds(delay))} catch {return}
            guard let self else {return}
            self.task = nil
            wake()
        }
    }
    deinit {task?.cancel()}
}
