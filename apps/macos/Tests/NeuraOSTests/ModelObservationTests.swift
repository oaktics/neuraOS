import XCTest
import Observation
@testable import NeuraOS

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var changed: Bool {lock.lock(); defer {lock.unlock()}; return value}
    func mark() {lock.lock(); value = true; lock.unlock()}
}

final class ModelObservationTests: XCTestCase {
    @MainActor func testUnchangedPollDoesNotInvalidateAnySnapshotReaders() {
        let model = AppModel(startPolling: false)
        let snapshot = fixture()
        model.applySnapshot(snapshot)
        model.updateConnection(true)
        let flag = ObservationFlag()
        withObservationTracking {
            _ = model.state.projects; _ = model.state.workspaces; _ = model.state.terminals
            _ = model.state.features; _ = model.openedIds; _ = model.connected
        } onChange: {flag.mark()}
        for _ in 0..<10 {
            model.applySnapshot(snapshot)
            model.updateConnection(true)
        }
        XCTAssertFalse(flag.changed)
    }

    @MainActor func testDisconnectOnlyNotifiesOnceAndReconnectIsObserved() {
        let model = AppModel(startPolling: false)
        model.updateConnection(true)
        let disconnected = ObservationFlag()
        withObservationTracking {_ = model.connected} onChange: {disconnected.mark()}
        model.updateConnection(false)
        XCTAssertTrue(disconnected.changed)
        let reconnected = ObservationFlag()
        withObservationTracking {_ = model.connected} onChange: {reconnected.mark()}
        model.updateConnection(false)
        XCTAssertFalse(reconnected.changed)
        model.updateConnection(true)
        XCTAssertTrue(reconnected.changed)
    }

    @MainActor func testTerminalActivityOnlyInvalidatesTerminalReaders() {
        let model = AppModel(startPolling: false)
        var snapshot = fixture()
        model.applySnapshot(snapshot)
        model.selectedId = "workspace"
        let chrome = ObservationFlag(), terminal = ObservationFlag()
        withObservationTracking {
            // Dependencies of the title bar, project menus and tab commands.
            _ = model.state.projects; _ = model.state.features; _ = model.selected
            _ = model.openedIds; _ = model.connected; _ = model.showSidebar
        } onChange: {chrome.mark()}
        withObservationTracking {_ = model.terminal(id: "terminal")}
            onChange: {terminal.mark()}
        snapshot.revision += 1
        snapshot.terminals[0].activity = "waiting"
        model.applySnapshot(snapshot)
        XCTAssertTrue(terminal.changed)
        XCTAssertFalse(chrome.changed)
        XCTAssertEqual(model.terminal(id: "terminal")?.activity, "waiting")
    }

    @MainActor func testUsageAndPendingActionsDoNotInvalidateUnrelatedNavigation() {
        let model = AppModel(startPolling: false)
        model.applySnapshot(fixture())
        let navigation = ObservationFlag(), usage = ObservationFlag()
        withObservationTracking {
            _ = model.selected; _ = model.state.projects; _ = model.showSidebar
            _ = model.showInspector; _ = model.state.features
        } onChange: {navigation.mark()}
        withObservationTracking {_ = model.providerUsage} onChange: {usage.mark()}
        model.providerUsage = [ProviderUsage(provider: "codex", status: "available", windows: [], checkedAt: "now")]
        XCTAssertTrue(model.beginAction("other-workspace", label: "Working"))
        model.endAction("other-workspace")
        XCTAssertTrue(usage.changed)
        XCTAssertFalse(navigation.changed)
    }

    @MainActor func testRealChangesStillReachTheirReadersAndRemovedWorkspacesArePruned() {
        let model = AppModel(startPolling: false)
        var snapshot = fixture()
        model.applySnapshot(snapshot)
        model.openedIds = ["workspace"]
        model.connected = true
        let projects = ObservationFlag(), workspaces = ObservationFlag(), capabilities = ObservationFlag()
        withObservationTracking {_ = model.state.projects} onChange: {projects.mark()}
        withObservationTracking {_ = model.state.workspaces; _ = model.openedIds} onChange: {workspaces.mark()}
        withObservationTracking {_ = model.supportsGitHub} onChange: {capabilities.mark()}
        snapshot.projects[0].worktreeStartup = ["codex"]
        snapshot.workspaces = []
        snapshot.features = ["github"]
        model.applySnapshot(snapshot)
        XCTAssertTrue(projects.changed)
        XCTAssertTrue(workspaces.changed)
        XCTAssertTrue(capabilities.changed)
        XCTAssertTrue(model.openedIds.isEmpty)
        XCTAssertTrue(model.supportsGitHub)
    }

    @MainActor func testLifecycleEventsSurviveACompleteActionBetweenRenderPasses() {
        let model = AppModel(startPolling: false)
        var releases = 0, launches = 0
        let actions = model.pendingActionsChanged.sink {if !model.isBusy("workspace") {releases += 1}}
        let terminals = model.terminalLaunchesChanged.sink {launches += 1}
        XCTAssertTrue(model.beginAction("workspace", label: "Working"))
        model.endAction("workspace")
        XCTAssertTrue(model.beginTerminalLaunch("tab"))
        model.endTerminalLaunch("tab")
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(launches, 2)
        withExtendedLifetime((actions, terminals)) {}
    }

    private func fixture() -> Snapshot {
        Snapshot(revision: 1, features: ["terminal.multiple"],
                 projects: [Project(id: "project", name: "Project", path: "/tmp/project", isGit: true)],
                 workspaces: [Workspace(id: "workspace", projectId: "project", name: "Workspace", path: "/tmp/project", branch: "main", kind: "root")],
                 terminals: [TerminalRecord(id: "terminal", workspaceId: "workspace", provider: "codex", status: "running", cols: 80, rows: 24, activity: "working")])
    }
}
