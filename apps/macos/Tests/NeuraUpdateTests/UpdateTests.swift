import XCTest
import Foundation
@testable import NeuraUpdateKit

final class UpdateTests: XCTestCase {
    func fixture() throws -> (URL, UpdateEngine) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("neura-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock {try? FileManager.default.removeItem(at: home)}
        let helper = home.appendingPathComponent("helper")
        try Data("test native helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        var engine = UpdateEngine(home: home, helper: helper)
        engine.run = {_,_,_ in CommandResult()}; engine.pause = {_ in}
        engine.daemonState = {nil}
        return (home, engine)
    }
    func testLaunchAgentRunsOnlyNativeDaemonAndEscapesPaths() throws {
        let (_, engine) = try fixture()
        let daemon = engine.home.appendingPathComponent("a & b/native")
        let object = try XCTUnwrap(PropertyListSerialization.propertyList(from: engine.launchAgent(daemon: daemon), format: nil) as? [String: Any])
        XCTAssertEqual(object["ProgramArguments"] as? [String], [daemon.path])
        XCTAssertEqual((object["EnvironmentVariables"] as? [String:String])?["NEURA_DEV_PORT"], "4318")
    }
    func testLaunchAgentRetriesOnlyTransientEIO() throws {
        let (_, original) = try fixture(); var engine = original; var attempts = 0
        engine.run = {_,args,_ in
            if args.first == "bootout" {return CommandResult(status: 3)}
            if args.first == "bootstrap" {attempts += 1; return CommandResult(status: attempts < 3 ? 5 : 0)}
            return CommandResult()
        }
        try engine.installService(daemon: engine.helper); XCTAssertEqual(attempts, 3)
        engine.run = {_,args,_ in CommandResult(status: args.first == "bootout" ? 1 : 0, output: "permission denied")}
        XCTAssertThrowsError(try engine.installService(daemon: engine.helper))
    }
    func testBootstrapPreservesRunningLegacyAndOtherNativeServices() throws {
        for executable in ["/old/Runtime/bin/node", "/another/Runtime/bin/neura-native-core"] {
            let (_, original) = try fixture(); var engine = original
            try FileManager.default.createDirectory(at: engine.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let old = try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": [executable]], format: .xml, options: 0)
            try old.write(to: engine.plist)
            engine.run = {program, args, _ in
                XCTAssertEqual(program, "/bin/launchctl"); XCTAssertEqual(args.first, "print")
                return CommandResult(output: "service = {\n    state = running\n    pid = 12345\n}\n")
            }
            try engine.bootstrap()
            XCTAssertEqual(try Data(contentsOf: engine.plist), old)
        }
    }
    func testBootstrapRepairsStoppedOrMissingService() throws {
        for status in [CommandResult(output: "service = {\n state = not running\n}\n"), CommandResult(status: 113)] {
            let (_, original) = try fixture(); var engine = original
            let daemon = engine.helper.deletingLastPathComponent().appendingPathComponent("neura-native-core")
            try Data("fixture".utf8).write(to: daemon)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemon.path)
            var started = false
            engine.run = {_, args, _ in
                if args.first == "print" {return status}
                if args.first == "bootstrap" {started = true}
                return CommandResult()
            }
            try engine.bootstrap(); XCTAssertTrue(started)
        }
    }
    func testDevelopmentEnsurePreservesLiveServiceAndUsesExplicitNativePathWhenStopped() throws {
        for running in [true, false] {
            let (home, original) = try fixture(); var engine = original
            let daemon = home.appendingPathComponent("development-native-core")
            try Data("fixture".utf8).write(to: daemon)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemon.path)
            var installed = false
            engine.run = {_, args, _ in
                if args.first == "print" {return running ? CommandResult(output: "pid = 12345\n") : CommandResult(status: 113)}
                if args.first == "bootstrap" {installed = true}
                return CommandResult()
            }
            _ = try engine.service("ensure", daemon: daemon)
            XCTAssertEqual(installed, !running)
            if !running {
                let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: engine.plist), format: nil) as? [String: Any])
                XCTAssertEqual(plist["ProgramArguments"] as? [String], [daemon.path])
            }
        }
    }
    func testCommandReturnsOnlyBoundedTail() throws {
        let result = try NativeCommand.run("/bin/sh", ["-c", "dd if=/dev/zero bs=1048576 count=8 2>/dev/null; printf tail-marker"], 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 65536)
        XCTAssertTrue(result.output.hasSuffix("tail-marker"))
    }
    func testTimeoutKillsTermIgnoringProcessGroupBeforeReturning() throws {
        let (home, _) = try fixture(); let marker = home.appendingPathComponent("heartbeat")
        let shell = "trap '' TERM; (trap '' TERM; while :; do echo alive >> '\(marker.path)'; sleep 0.02; done) & wait"
        XCTAssertThrowsError(try NativeCommand.run("/bin/sh",["-c",shell],0.3))
        let size = try Data(contentsOf:marker).count; Thread.sleep(forTimeInterval:0.2)
        XCTAssertEqual(try Data(contentsOf:marker).count,size)
    }

    // MARK: reconcile after a Sparkle update

    /// Installs a LaunchAgent that points at `daemon` and reports it running.
    func runningService(_ engine: inout UpdateEngine, daemon: URL, calls: Box<[[String]]>) throws {
        try FileManager.default.createDirectory(at: engine.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": [daemon.path]], format: .xml, options: 0).write(to: engine.plist)
        try Data("fixture".utf8).write(to: engine.bundledDaemon)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.bundledDaemon.path)
        engine.run = {program, args, _ in
            calls.value.append([program] + args)
            return args.first == "print" ? CommandResult(output: "pid = 12345\n") : CommandResult()
        }
    }
    func restarted(_ calls: [[String]]) -> Bool {calls.contains {$0.prefix(2) == ["/bin/launchctl", "bootstrap"]}}

    func testReconcileLeavesMatchingDaemonRunning() async throws {
        let (_, original) = try fixture(); var engine = original; let calls = Box<[[String]]>([])
        try runningService(&engine, daemon: engine.bundledDaemon, calls: calls)
        engine.daemonState = {DaemonIdentity(runtime: "rust", daemonInstanceId: UUID().uuidString, daemonBuild: 80)}
        let state = try await engine.reconcile(build: 80, approved: true)
        XCTAssertEqual(state, .current); XCTAssertFalse(restarted(calls.value))
    }
    func testReconcileNeverTouchesAnotherAppsService() async throws {
        let (home, original) = try fixture(); var engine = original; let calls = Box<[[String]]>([])
        try runningService(&engine, daemon: home.appendingPathComponent("Other.app/neura-native-core"), calls: calls)
        engine.daemonState = {DaemonIdentity(runtime: "rust", daemonInstanceId: UUID().uuidString, daemonBuild: 70)}
        let state = try await engine.reconcile(build: 80, approved: true)
        XCTAssertEqual(state, .foreign); XCTAssertFalse(restarted(calls.value))
    }
    func testReconcileAsksBeforeRestartingStaleDaemon() async throws {
        let (_, original) = try fixture(); var engine = original; let calls = Box<[[String]]>([])
        try runningService(&engine, daemon: engine.bundledDaemon, calls: calls)
        // Daemons released before this change do not report a build number.
        engine.daemonState = {DaemonIdentity(runtime: "rust", daemonInstanceId: UUID().uuidString)}
        let state = try await engine.reconcile(build: 80, approved: false)
        XCTAssertEqual(state, .needsRestart); XCTAssertFalse(restarted(calls.value))
    }
    func testReconcileRestartsStaleDaemonWithFreshRelaunchApproval() async throws {
        let (_, original) = try fixture(); var engine = original; let calls = Box<[[String]]>([])
        try runningService(&engine, daemon: engine.bundledDaemon, calls: calls)
        try FileManager.default.createDirectory(at: engine.updates, withIntermediateDirectories: true)
        try Data().write(to: engine.relaunchApproval)
        try Data("old failure".utf8).write(to: engine.lastError)
        let old = DaemonIdentity(runtime: "rust", daemonInstanceId: UUID().uuidString, daemonBuild: 79)
        let new = DaemonIdentity(runtime: "rust", daemonInstanceId: UUID().uuidString, daemonBuild: 80)
        engine.daemonState = {self.restarted(calls.value) ? new : old}
        let state = try await engine.reconcile(build: 80, approved: false)
        XCTAssertEqual(state, .migrated); XCTAssertTrue(restarted(calls.value))
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.relaunchApproval.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.lastError.path))
    }
    func testStaleRelaunchApprovalIsIgnoredAndConsumed() async throws {
        let (_, original) = try fixture(); var engine = original; let calls = Box<[[String]]>([])
        try runningService(&engine, daemon: engine.bundledDaemon, calls: calls)
        try FileManager.default.createDirectory(at: engine.updates, withIntermediateDirectories: true)
        try Data().write(to: engine.relaunchApproval)
        engine.now = {Date().addingTimeInterval(3600)}
        engine.daemonState = {DaemonIdentity(runtime: "rust", daemonInstanceId: UUID().uuidString, daemonBuild: 79)}
        let state = try await engine.reconcile(build: 80, approved: false)
        XCTAssertEqual(state, .needsRestart); XCTAssertFalse(restarted(calls.value))
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.relaunchApproval.path))
    }
    func testReconcileRecordsFailureWhenNewDaemonRunsTheOldBuild() async throws {
        let (_, original) = try fixture(); var engine = original; let calls = Box<[[String]]>([])
        try runningService(&engine, daemon: engine.bundledDaemon, calls: calls)
        let old = DaemonIdentity(runtime: "rust", daemonInstanceId: UUID().uuidString, daemonBuild: 79)
        // A fresh instance that still runs the previous build is not success.
        engine.daemonState = {self.restarted(calls.value) ? DaemonIdentity(runtime: "rust", daemonInstanceId: UUID().uuidString, daemonBuild: 79) : old}
        do {_ = try await engine.reconcile(build: 80, approved: true); XCTFail("Expected failure")} catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.lastError.path))
    }
    func testReconcileInstallsStoppedService() async throws {
        let (_, original) = try fixture(); var engine = original; var started = false
        try Data("fixture".utf8).write(to: engine.bundledDaemon)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.bundledDaemon.path)
        engine.run = {_, args, _ in
            if args.first == "print" {return CommandResult(status: 113)}
            if args.first == "bootstrap" {started = true}
            return CommandResult()
        }
        let state = try await engine.reconcile(build: 80, approved: false)
        XCTAssertEqual(state, .installed); XCTAssertTrue(started)
    }
}

final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) {self.value = value}
}
