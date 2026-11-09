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

    @MainActor func testActivityAndResizeDoNotInvalidateTabMembershipOrDeletionPresentation() {
        let model = AppModel(startPolling: false)
        var snapshot = fixture()
        model.applySnapshot(snapshot)
        model.pendingWorkspaceDeletion = snapshot.workspaces[0]
        let membership = ObservationFlag(), confirmation = ObservationFlag()
        withObservationTracking {_ = model.state.terminalMembership} onChange: {membership.mark()}
        withObservationTracking {
            _ = model.pendingWorkspaceDeletion
            _ = model.state.features
        } onChange: {confirmation.mark()}
        for index in 0..<20 {
            snapshot.revision += 1
            snapshot.terminals = [TerminalRecord(id: "terminal", workspaceId: "workspace", provider: "codex",
                status: index == 19 ? "exited" : "running", cols: 80 + index, rows: 24,
                activity: index.isMultiple(of: 2) ? "working" : "waiting")]
            model.applySnapshot(snapshot)
        }
        XCTAssertFalse(membership.changed)
        XCTAssertFalse(confirmation.changed)
        XCTAssertEqual(model.terminal(id: "terminal")?.status, "exited")
        snapshot.terminals.append(TerminalRecord(id: "new", workspaceId: "workspace", provider: "shell",
            status: "running", cols: 80, rows: 24))
        model.applySnapshot(snapshot)
        XCTAssertTrue(membership.changed)
        XCTAssertFalse(confirmation.changed)
        XCTAssertEqual(model.state.terminalMembership.map(\.id), ["terminal", "new"])
        let removal = ObservationFlag()
        withObservationTracking {_ = model.state.terminalMembership} onChange: {removal.mark()}
        snapshot.terminals = []
        model.applySnapshot(snapshot)
        XCTAssertTrue(removal.changed)
    }

    @MainActor func testThousandWorkspaceReadersOnlyInvalidateChangedTerminalAndWorkspace() {
        let model = AppModel(startPolling: false)
        var snapshot = Snapshot()
        snapshot.terminals = (0..<1_000).map {
            TerminalRecord(id: "t\($0)", workspaceId: "w\($0)", provider: "codex",
                           status: "running", cols: 80, rows: 24, activity: "working")
        }
        model.applySnapshot(snapshot)
        let terminalFlags = (0..<1_000).map {_ in ObservationFlag()}
        let workspaceFlags = (0..<1_000).map {_ in ObservationFlag()}
        let membershipFlags = (0..<1_000).map {_ in ObservationFlag()}
        for index in 0..<1_000 {
            let terminal = terminalFlags[index], workspace = workspaceFlags[index], membership = membershipFlags[index]
            withObservationTracking {_ = model.terminal(id: "t\(index)")} onChange: {terminal.mark()}
            withObservationTracking {_ = model.state.terminals(in: "w\(index)")} onChange: {workspace.mark()}
            withObservationTracking {_ = model.state.workspaceTerminals("w\(index)").membership} onChange: {membership.mark()}
        }
        snapshot.terminals[500].activity = "waiting"
        model.applySnapshot(snapshot)
        XCTAssertEqual(terminalFlags.filter(\.changed).count, 1)
        XCTAssertEqual(workspaceFlags.filter(\.changed).count, 1)
        XCTAssertEqual(membershipFlags.filter(\.changed).count, 0)
        XCTAssertTrue(terminalFlags[500].changed)
        XCTAssertTrue(workspaceFlags[500].changed)
    }

    @MainActor func testScopedReadersObserveCreationRemovalAndWorkspaceMove() {
        let state = DaemonViewState()
        let created = ObservationFlag()
        withObservationTracking {_ = state.terminal(id: "terminal")} onChange: {created.mark()}
        var snapshot = fixture()
        state.apply(snapshot)
        XCTAssertTrue(created.changed)
        let removed = ObservationFlag(), oldWorkspace = ObservationFlag(), newWorkspace = ObservationFlag()
        withObservationTracking {_ = state.terminal(id: "terminal")} onChange: {removed.mark()}
        withObservationTracking {_ = state.terminals(in: "workspace")} onChange: {oldWorkspace.mark()}
        withObservationTracking {_ = state.terminals(in: "moved")} onChange: {newWorkspace.mark()}
        snapshot.terminals = [TerminalRecord(id: "terminal", workspaceId: "moved", provider: "codex", status: "exited", cols: 80, rows: 24)]
        state.apply(snapshot)
        XCTAssertTrue(removed.changed && oldWorkspace.changed && newWorkspace.changed)
        XCTAssertTrue(state.terminals(in: "workspace").isEmpty)
        XCTAssertEqual(state.terminals(in: "moved").count, 1)
        snapshot.terminals = []
        state.apply(snapshot)
        XCTAssertNil(state.terminal(id: "terminal"))
        XCTAssertTrue(state.terminals(in: "moved").isEmpty)
        XCTAssertTrue(state.workspaceTerminals("moved").membership.isEmpty)
    }

    private func fixture() -> Snapshot {
        Snapshot(revision: 1, features: ["terminal.multiple"],
                 projects: [Project(id: "project", name: "Project", path: "/tmp/project", isGit: true)],
                 workspaces: [Workspace(id: "workspace", projectId: "project", name: "Workspace", path: "/tmp/project", branch: "main", kind: "root")],
                 terminals: [TerminalRecord(id: "terminal", workspaceId: "workspace", provider: "codex", status: "running", cols: 80, rows: 24, activity: "working")])
    }
}
