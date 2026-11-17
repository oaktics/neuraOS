import AppKit
import Network

@MainActor final class SleepHistoryMonitor {
    let store: SleepHistoryStore
    private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
    private var observers: [NSObjectProtocol] = []
    private var probe: Task<Void, Never>?
    private var timer: Timer?
    private var lastTick = Date()
    private var sleepAt: Date?
    private var values: [String: (Bool, Date)] = [:]
    private var lastLid: Bool?
    private var lidUnavailable = false
    private var tracker = SleepAgentTracker()
    private var agentPoll: Task<Void, Never>?
    private var api: DaemonClient?
    var projects: [String: String] = [:]
    var sample: (() -> Void)?
    init(store: SleepHistoryStore) {self.store = store}
    func start(api: DaemonClient) {
        guard self.api == nil else {return}
        self.api = api
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {return}
                let now = Date(); self.sleepAt = now
                self.store.append(.init(date: now, kind: .sleep, source: .os, reason: .changed))
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {return}
                let now = Date()
                self.store.append(.init(date: now, kind: .gap, source: .observation, reason: .systemSleep, since: self.sleepAt))
                self.store.append(.init(date: now, kind: .wake, source: .os, reason: .changed, since: self.sleepAt))
                self.sleepAt = nil; self.lastTick = now; self.sample?()
            }
        })
        wifi.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.transition("wifi", up: up, yes: .wifiUp, no: .wifiDown, reason: .changed) }
        }
        wifi.start(queue: DispatchQueue(label: "neura.sleep-history.wifi"))
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {self?.tick()}
        }
        RunLoop.main.add(timer!, forMode: .common)
        probe = Task { [weak self] in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
            config.httpCookieStorage = nil; config.urlCache = nil
            let session = URLSession(configuration: config)
            defer {session.invalidateAndCancel()}
            while !Task.isCancelled {
                var request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                var up = false
                if let (data, response) = try? await session.data(for: request),
                   let http = response as? HTTPURLResponse {
                    up = http.statusCode == 200 && response.url?.host == "captive.apple.com" &&
                        String(data: data, encoding: .utf8)?.contains("<TITLE>Success</TITLE>") == true
                }
                guard !Task.isCancelled else {break}
                self?.transition("internet", up: up, yes: .internetUp, no: .internetDown, reason: .endpointProbe)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        tick()
    }
    func transition(_ key: String, up: Bool, yes: SleepHistoryEvent.Kind, no: SleepHistoryEvent.Kind, reason: SleepHistoryEvent.Reason) {
        let old = values[key]
        guard old?.0 != up else {return}
        let now = Date()
        store.append(.init(date: now, kind: up ? yes : no, source: .observation, reason: old == nil && no != .gap ? .initial : reason, since: old?.1))
        values[key] = (up, now)
    }
    func daemon(connected: Bool) {
        transition("daemon", up: connected, yes: .daemonUp, no: .daemonDown, reason: .causeUnknown)
    }
    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastTick) > 10 && sleepAt == nil {
            store.append(.init(date: now, kind: .gap, source: .observation, reason: .samplingGap, since: lastTick))
        }
        lastTick = now
        let closed = LidState.closed
        if let closed {
            if lastLid != closed {
                store.append(.init(date: now, kind: closed ? .lidClosed : .lidOpened, source: .os, reason: lastLid == nil ? .initial : .changed))
            }
            lidUnavailable = false
        } else if !lidUnavailable {
            store.append(.init(date: now, kind: .lidUnavailable, source: .observation, reason: .unavailable)); lidUnavailable = true
        }
        lastLid = closed
        sample?(); store.checkpoint()
        guard agentPoll == nil, let api else {return}
        agentPoll = Task { [weak self] in
            guard let self else {return}
            defer {self.agentPoll = nil}
            do {
                var cursor: String?; var agents: [SleepAgentState] = []
                repeat {
                    var options: [String: Any] = ["summaryOnly": true, "limit": 500]
                    if let cursor {options["cursor"] = cursor}
                    let json = String(data: try JSONSerialization.data(withJSONObject: options), encoding: .utf8)!
                    let page: SleepAgentPage = try await api.get("v1/agents", query: ["options": json])
                    guard page.fullRefreshRequired != true else {throw CocoaError(.fileReadUnknown)}
                    agents += page.agents; cursor = page.nextCursor
                } while cursor != nil && !Task.isCancelled
                guard !Task.isCancelled else {return}
                for event in tracker.observe(agents, projects: projects, now: Date()) {store.append(event)}
                if let missing = values.removeValue(forKey: "agent-observation") {
                    store.append(.init(date: Date(), kind: .gap, source: .observation, reason: .agentUnavailable, since: missing.1))
                }
            } catch {
                // Failure of the listing transport is not proof of provider failure.
                transition("agent-observation", up: false, yes: .daemonUp, no: .gap, reason: .agentUnavailable)
            }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil; wifi.cancel(); probe?.cancel(); agentPoll?.cancel()
        for observer in observers {NSWorkspace.shared.notificationCenter.removeObserver(observer)}
        observers.removeAll(); store.flush()
    }
}
