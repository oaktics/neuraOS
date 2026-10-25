import XCTest
@testable import NeuraOS

final class TerminalCompatibilityTests: XCTestCase {
    @MainActor func testPendingLaunchOnlyProtectsItsOwningTabUntilCompletion() async {
        let model = AppModel(startPolling: false)
        XCTAssertTrue(model.beginTerminalLaunch("starting-tab"))
        XCTAssertFalse(model.beginTerminalLaunch("starting-tab"))
        XCTAssertTrue(model.isTerminalStarting("starting-tab"))
        XCTAssertFalse(model.isTerminalStarting("unrelated-tab"))
        let workspace = Workspace(id: "legacy", projectId: "test", name: "test", path: "/nonexistent", branch: "", kind: "folder")
        let terminal = await model.openTerminal(workspace, provider: "shell")
        XCTAssertNil(terminal)
        // The caller owns the guard through terminal binding assignment, even after open returns.
        XCTAssertTrue(model.isTerminalStarting("starting-tab"))
        model.endTerminalLaunch("starting-tab")
        XCTAssertFalse(model.isTerminalStarting("starting-tab"))
        XCTAssertTrue(model.beginTerminalLaunch("starting-tab"))
        model.endTerminalLaunch("starting-tab")
    }

    @MainActor func testConcurrentLegacyOpensAreRejectedBeforeSendingCommands() async {
        let model = AppModel(startPolling: false)
        model.connected = true
        model.state.features = ["github"]
        let workspace = Workspace(id: "legacy-test", projectId: "test", name: "test", path: "/nonexistent", branch: "main", kind: "root")
        async let first = model.openTerminal(workspace, provider: "shell")
        async let second = model.openTerminal(workspace, provider: "shell")
        let results = await (first, second)
        XCTAssertNil(results.0)
        XCTAssertNil(results.1)
        XCTAssertEqual(model.error, "Daemonの更新が必要です。実行中の作業を終えてから pnpm service restart を実行してください。")
        XCTAssertFalse(model.isBusy(workspace.id))
        XCTAssertTrue(model.state.terminals.isEmpty)
    }
}
