import Foundation
import NeuraUpdateKit
import Darwin

// App replacement is done by Sparkle. This helper only owns the daemon's
// LaunchAgent: first-run registration and switching to the bundled daemon
// after the app was updated.
@main enum NeuraUpdaterMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let engine = UpdateEngine(helper: helper)
        do {
            switch args.first {
            case "bootstrap": try engine.bootstrap()
            case "reconcile" where (2...3).contains(args.count):
                guard let build = Int(args[1]), args.count == 2 || args[2] == "--approved" else {throw UpdateFailure("Usage: reconcile <build> [--approved]")}
                let state = try await engine.reconcile(build: build, approved: args.count == 3)
                print(String(decoding: try JSONEncoder().encode(["state": state.rawValue]), as: UTF8.self))
            case "service":
                print(try engine.service(args.count > 1 ? args[1] : "status", daemon: args.count > 2 ? URL(fileURLWithPath: args[2]) : engine.bundledDaemon))
            default: throw UpdateFailure("Unknown update command")
            }
        } catch {fputs(error.localizedDescription + "\n", stderr); exit(1)}
    }
}
