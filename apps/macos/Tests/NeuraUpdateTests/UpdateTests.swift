import XCTest
import Foundation
import CryptoKit
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
        engine.run = {_,_,_ in CommandResult()}; engine.pause = {_ in}; engine.parentExists = {_ in false}
        engine.launch = {_,_ in XCTFail("Unexpected installer launch")}
        return (home, engine)
    }
    func release(_ mutate: (inout [String: Any]) -> Void = {_ in}) throws -> NativeRelease {
        let bytes = Data("archive".utf8)
        let digest = SHA256.hash(data: bytes).map {String(format: "%02x", $0)}.joined()
        var value: [String: Any] = ["tag_name": "native-42", "assets": [["name":"neuraOS-darwin-arm64.zip", "digest":"sha256:\(digest)", "browser_download_url":"https://github.com/oaktics/neuraOS/releases/download/native-42/neuraOS-darwin-arm64.zip"]]]
        mutate(&value)
        return try NativeRelease.validate(JSONSerialization.data(withJSONObject: value), architecture: "arm64")
    }
    func createApp(_ app: URL, marker: String) throws {
        let bin = app.appendingPathComponent("Contents/Resources/Runtime/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("marker"))
        for name in ["neura-native-core","neura-updater"] {
            let file = bin.appendingPathComponent(name); try Data("fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
    }
    func staged(_ engine: UpdateEngine) throws -> URL {
        let stage = engine.updates.appendingPathComponent("stage-test")
        try createApp(engine.target, marker: "old")
        try createApp(stage.appendingPathComponent("neuraOS.app"), marker: "new")
        try FileManager.default.createDirectory(at: engine.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old-service".utf8).write(to: engine.plist)
        try FileManager.default.createDirectory(at: engine.updates.appendingPathComponent("install.lock"), withIntermediateDirectories: true)
        return stage
    }
    func testReleaseValidationAndDigestFailClosed() throws {
        let value = try release(); XCTAssertEqual(value.build, 42)
        try value.verify(Data("archive".utf8)); XCTAssertThrowsError(try value.verify(Data("tampered".utf8)))
        for mutation: (inout [String: Any]) -> Void in [{$0["draft"] = true}, {$0["prerelease"] = true}, {$0["tag_name"] = "../../evil"}, {$0["assets"] = []}, {$0["assets"] = [["name":"neuraOS-darwin-arm64.zip","digest":"sha256:"+String(repeating:"a",count:64),"browser_download_url":"https://evil.invalid/archive.zip"]]}] {
            XCTAssertThrowsError(try release(mutation))
        }
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
    func testHealthyInstallKeepsBackupAndStartsNativeService() async throws {
        let (_, original) = try fixture(); var engine = original
        let stage = try staged(engine); var calls: [[String]] = []
        engine.run = {program,args,_ in calls.append([program]+args); return CommandResult()}; engine.health = {true}
        try await engine.apply(stage: stage, parentPID: 123)
        XCTAssertEqual(try String(contentsOf: engine.target.appendingPathComponent("marker")), "new")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: engine.target.path+".previous/marker")), "old")
        XCTAssertTrue(calls.contains { $0.prefix(2) == ["/bin/launchctl","bootstrap"] })
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: engine.plist), format: nil) as? [String:Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [engine.target.appendingPathComponent("Contents/Resources/Runtime/bin/neura-native-core").path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
    func testUnhealthyInstallRestoresOldAppAndOldService() async throws {
        let (_, original) = try fixture(); var engine = original
        let stage = try staged(engine); engine.health = {false}; var calls: [[String]] = []
        engine.run = {program,args,_ in calls.append([program]+args); return CommandResult()}
        do {try await engine.apply(stage: stage, parentPID: 123); XCTFail("Expected unhealthy failure")} catch {}
        XCTAssertEqual(try String(contentsOf: engine.target.appendingPathComponent("marker")), "old")
        XCTAssertEqual(try String(contentsOf: engine.plist), "old-service")
        XCTAssertTrue(calls.contains { $0.prefix(2) == ["/bin/launchctl","bootstrap"] })
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.updates.appendingPathComponent("last-error.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.updates.appendingPathComponent("install.lock").path))
    }
    func testLegacyNodeMigrationAndRollbackPreserveOldRuntimeAndPlist() async throws {
        for healthy in [true, false] {
            let (_, original) = try fixture(); var engine = original
            let stage = try staged(engine)
            let runtime = engine.target.appendingPathComponent("Contents/Resources/Runtime")
            try FileManager.default.removeItem(at: runtime)
            try FileManager.default.createDirectory(at: runtime.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try Data("legacy Node fixture".utf8).write(to: runtime.appendingPathComponent("bin/node"))
            try FileManager.default.createDirectory(at: runtime.appendingPathComponent("node_modules/tsx"), withIntermediateDirectories: true)
            let oldPlist = try PropertyListSerialization.data(fromPropertyList: ["Label": UpdateEngine.serviceID,
                "ProgramArguments": [runtime.appendingPathComponent("bin/node").path, "--import", "tsx", "apps/daemon/src/main.ts"]], format: .xml, options: 0)
            try oldPlist.write(to: engine.plist)
            var bootstrappedArguments: [[String]] = []
            engine.run = {program, args, _ in
                if program == "/bin/launchctl", args.first == "bootstrap" {
                    let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: engine.plist), format: nil) as! [String: Any]
                    bootstrappedArguments.append(value["ProgramArguments"] as! [String])
                }
                return CommandResult()
            }
            engine.health = {healthy}
            do {try await engine.apply(stage: stage, parentPID: 123); XCTAssertTrue(healthy)} catch {XCTAssertFalse(healthy)}
            XCTAssertEqual(try Data(contentsOf: engine.updates.appendingPathComponent("previous-launch-agent.plist")), oldPlist)
            let legacyApp = healthy ? URL(fileURLWithPath: engine.target.path + ".previous") : engine.target
            XCTAssertEqual(try String(contentsOf: legacyApp.appendingPathComponent("Contents/Resources/Runtime/bin/node")), "legacy Node fixture")
            if healthy {
                XCTAssertEqual(bootstrappedArguments.last?.count, 1)
                XCTAssertTrue(bootstrappedArguments.last?.first?.hasSuffix("/neura-native-core") == true)
                XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("bin/node").path))
            } else {
                XCTAssertEqual(try Data(contentsOf: engine.plist), oldPlist)
                XCTAssertTrue(bootstrappedArguments.last?.first?.hasSuffix("/bin/node") == true)
            }
        }
    }
    func testApplicationRefusingExitLeavesAppAndServiceUntouched() async throws {
        let (_, original) = try fixture(); var engine = original
        let stage = try staged(engine); engine.parentExists = {_ in true}
        engine.run = {_,_,_ in XCTFail("Must not touch service before parent exit"); return CommandResult()}
        do {try await engine.apply(stage: stage, parentPID: 123); XCTFail("Expected exit refusal")} catch {}
        XCTAssertEqual(try String(contentsOf: engine.target.appendingPathComponent("marker")), "old")
        XCTAssertEqual(try String(contentsOf: engine.plist), "old-service")
    }
    func testPrepareTimeoutCleansOnlyOwnedStageAndLock() async throws {
        let (_, original) = try fixture(); var engine = original; let candidate = try release()
        engine.run = {_,_,_ in throw UpdateFailure("timeout")}
        do {try await engine.prepare(tag: candidate.tag, parentPID: 123, latest: {candidate}, download: {_ in Data("archive".utf8)}); XCTFail("Expected timeout")} catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: engine.updates.path), [])
    }
    func testPrepareRejectsGatekeeperFailureAndDoesNotLaunch() async throws {
        let (_, original) = try fixture(); var engine = original; let candidate = try release()
        engine.run = {program,_,_ in CommandResult(status: program == "/usr/sbin/spctl" ? 1 : 0, output: "rejected")}
        do {try await engine.prepare(tag: candidate.tag, parentPID: 123, latest: {candidate}, download: {_ in Data("archive".utf8)}); XCTFail("Expected trust rejection")} catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: engine.updates.path), [])
    }
    func testPrepareCopiesNativeInstallerOutsideApplicationBeforeLaunching() async throws {
        let (_, original) = try fixture(); var engine = original; let candidate = try release(); var launched = false
        engine.run = {program,args,_ in
            if program == "/usr/bin/ditto" {try self.createApp(URL(fileURLWithPath: args.last!).appendingPathComponent("neuraOS.app"), marker: "new")}
            if program == "/usr/libexec/PlistBuddy" {return CommandResult(output: args[1].contains("Identifier") ? "app.neuraos.native\n" : "42\n")}
            return CommandResult()
        }
        engine.launch = {path,args in launched = true; XCTAssertTrue(path.hasPrefix(engine.updates.path)); XCTAssertEqual(args.first,"apply"); XCTAssertEqual(args.last,"123"); XCTAssertTrue(FileManager.default.isExecutableFile(atPath:path))}
        try await engine.prepare(tag: candidate.tag, parentPID: 123, latest: {candidate}, download: {_ in Data("archive".utf8)})
        XCTAssertTrue(launched); XCTAssertTrue(FileManager.default.fileExists(atPath:engine.updates.appendingPathComponent("install.lock").path))
    }
    func testForeignApplyStageCannotDeleteFiles() async throws {
        let (home, engine) = try fixture(); let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        do {try await engine.apply(stage:outside,parentPID:123); XCTFail("Expected invalid stage")} catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath:outside.path))
    }
    func testTimeoutKillsTermIgnoringProcessGroupBeforeReturning() throws {
        let (home, _) = try fixture(); let marker = home.appendingPathComponent("heartbeat")
        let shell = "trap '' TERM; (trap '' TERM; while :; do echo alive >> '\(marker.path)'; sleep 0.02; done) & wait"
        XCTAssertThrowsError(try NativeCommand.run("/bin/sh",["-c",shell],0.3))
        let size = try Data(contentsOf:marker).count; Thread.sleep(forTimeInterval:0.2)
        XCTAssertEqual(try Data(contentsOf:marker).count,size)
    }
}
