import Foundation
import NeuraUpdateKit
import Darwin

@main enum NeuraUpdaterMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let engine = UpdateEngine(helper: helper), client = ReleaseClient()
        do {
            switch args.first {
            case "bootstrap": try engine.bootstrap()
            case "service":
                print(try engine.service(args.count > 1 ? args[1] : "status", daemon: args.count > 2 ? URL(fileURLWithPath: args[2]) : helper.deletingLastPathComponent().appendingPathComponent("neura-native-core")))
            case "check": print(String(decoding: try JSONEncoder().encode(await client.latest()), as: UTF8.self))
            case "prepare" where args.count == 3:
                guard let pid = Int32(args[2]) else {throw UpdateFailure("Invalid application PID")}
                try await engine.prepare(tag: args[1], parentPID: pid, latest: {try await client.latest()}, download: {try await client.download($0)})
                print("{\"ready\":true}")
            case "apply" where args.count == 3:
                guard let pid = Int32(args[2]) else {throw UpdateFailure("Invalid application PID")}
                try await engine.apply(stage: URL(fileURLWithPath: args[1]), parentPID: pid)
            default: throw UpdateFailure("Unknown update command")
            }
        } catch {fputs(error.localizedDescription + "\n", stderr); exit(1)}
    }
}
