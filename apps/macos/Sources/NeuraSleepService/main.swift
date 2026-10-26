import Foundation
import Darwin
import SleepControl

final class Client: NSObject, SleepServiceProtocol {
    let owner: uid_t
    let service: Service
    var connected = true
    var started = false
    init(owner: uid_t, service: Service) {self.owner = owner; self.service = service}
    func run(lease: String, token: String, withReply reply: @escaping (String) -> Void) {
        DispatchQueue.main.async { [self] in
            guard connected, !started else {reply("接続をやり直してください。"); return}
            started = true
            service.start(client: self, lease: lease, token: token, reply: reply)
        }
    }
}

final class Service: NSObject, NSXPCListenerDelegate {
    let power: PowerControl
    let clientRequirement: String
    var connections = 0
    var client: Client?
    var session: SleepSession?
    var reply: ((String) -> Void)?
    var timer: DispatchSourceTimer?
    init(power: PowerControl, clientRequirement: String) {self.power = power; self.clientRequirement = clientRequirement}

    func start(client: Client, lease: String, token: String, reply: @escaping (String) -> Void) {
        guard session == nil, SleepService.validRequest(lease: lease, token: token, owner: client.owner),
              SleepLease.read(path: lease, owner: client.owner, token: token) != nil else {
            reply("作業状態が無効か、別のスリープ制御が終了していません。再度有効にしてください。"); return
        }
        do {
            // Retry any incomplete restoration before considering a new session.
            try power.release()
            guard !FileManager.default.fileExists(atPath: "/var/run/neuraos-agent-sleep") else {
                throw SleepSessionError("旧バージョンのスリープ制御が終了していません。解除してから再度お試しください。")
            }
            session = try SleepSession(power: power)
            self.client = client; self.reply = reply
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, let session = self.session else {return}
                guard let state = SleepLease.read(path: lease, owner: client.owner, token: token) else {self.finish(""); return}
                do {
                    let message = try session.step(state: state, now: ProcessInfo.processInfo.systemUptime)
                    self.power.status(token: token, message: message)
                } catch {self.finish(error.localizedDescription)}
            }
            self.timer = timer; timer.resume()
        } catch {reply(error.localizedDescription)}
    }
    func finish(_ message: String) {
        timer?.cancel(); timer = nil
        var result = message
        var restored = true
        do {try session?.stop(); try power.release()}
        catch {restored = false; result = "スリープ設定の復元に失敗しました: " + error.localizedDescription}
        let completion = reply
        session = nil; client = nil; reply = nil
        completion?(result)
        // Keep a failed restoration visible and retry even if the client leaves.
        // A crash is recovered by launchd using the same root-owned marker.
        if !restored {exit(74)}
        exitWhenIdle()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier > 0 else {return false}
        let client = Client(owner: connection.effectiveUserIdentifier, service: self)
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: SleepServiceProtocol.self)
        connection.exportedObject = client
        DispatchQueue.main.async {self.connections += 1}
        connection.invalidationHandler = { [self, client] in
            DispatchQueue.main.async {
                client.connected = false
                self.connections -= 1
                if self.client === client {self.finish("")}
                self.exitWhenIdle()
            }
        }
        connection.resume()
        return true
    }
    func exitWhenIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            if connections == 0 && session == nil {
                do {try power.release(); exit(0)} catch {exit(74)}
            }
        }
    }
    func shutdown() {
        finish("")
        exit(0)
    }
}

guard geteuid() == 0 else {exit(77)}
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
do {
    // Recover before signature validation so an interrupted app update cannot
    // prevent restoration of a previous session's power setting.
    let power = try PowerControl()
    let service = Service(power: power, clientRequirement: try SleepService.requirement(for: app, requireHardenedRuntime: true))
    let listener = NSXPCListener(machServiceName: SleepService.name)
    listener.delegate = service
    listener.setConnectionCodeSigningRequirement(service.clientRequirement)
    let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {service.shutdown()}
        source.resume()
        return source
    }
    listener.resume()
    service.exitWhenIdle()
    withExtendedLifetime((service, listener, signals)) {dispatchMain()}
} catch {
    FileHandle.standardError.write(Data(("Sleep service failed: \(error)\n").utf8))
    exit(78)
}
