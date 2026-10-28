import XCTest
@testable import NeuraOS

final class SidebarSpacesTests: XCTestCase {
    func testExistingProjectsStayInMainAndSelectionsSurviveReload() throws {
        var layout = SidebarSpaces()
        let main = layout.active.id
        layout.remember("original-worktree")
        layout.create(name: "個人")
        let personal = layout.active.id
        XCTAssertEqual(layout.owner(of: "existing-project"), main)
        layout.projectSpaces["personal-project"] = personal
        layout.remember("personal-folder")
        let restored = try JSONDecoder().decode(SidebarSpaces.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored.active.id, personal)
        XCTAssertEqual(restored.active.selectedWorkspaceId, "personal-folder")
        XCTAssertEqual(restored.spaces.first?.selectedWorkspaceId, "original-worktree")
        XCTAssertEqual(restored.owner(of: "personal-project"), personal)
        XCTAssertEqual(restored.adjacent(-1), main)
        XCTAssertNil(restored.adjacent(1))
    }
    func testMovingProjectDoesNotMoveOtherProjects() {
        var layout = SidebarSpaces()
        let main = layout.active.id
        layout.create(name: "仕事")
        layout.projectSpaces["one"] = layout.active.id
        XCTAssertEqual(layout.owner(of: "one"), layout.active.id)
        XCTAssertEqual(layout.owner(of: "two"), main)
        layout.activeId = main
        XCTAssertNil(layout.adjacent(-1))
    }
    func testActivityFollowsProjectOwnershipAndAttentionTakesPriority() {
        var layout = SidebarSpaces()
        let main = layout.active.id
        layout.create(name: "仕事")
        let work = layout.active.id
        layout.projectSpaces["p2"] = work
        let workspaces = [
            Workspace(id: "w1", projectId: "p1", name: "one", path: "", branch: "", kind: "worktree"),
            Workspace(id: "w2", projectId: "p2", name: "two", path: "", branch: "", kind: "worktree")
        ]
        let terminals = [
            TerminalRecord(id: "t1", workspaceId: "w1", provider: "codex", status: "running", cols: 80, rows: 24, activity: "working"),
            TerminalRecord(id: "t2", workspaceId: "w2", provider: "claude", status: "running", cols: 80, rows: 24, activity: "waiting"),
            TerminalRecord(id: "orphan", workspaceId: "deleted", provider: "codex", status: "running", cols: 80, rows: 24, activity: "waiting")
        ]
        XCTAssertEqual(layout.activity(in: main, workspaces: workspaces, terminals: terminals, connected: true), .working)
        XCTAssertEqual(layout.activity(in: work, workspaces: workspaces, terminals: terminals, connected: true), .waiting)
        XCTAssertEqual(layout.activity(in: main, workspaces: workspaces, terminals: terminals, connected: false), .unknown)
        layout.projectSpaces["p2"] = main
        XCTAssertEqual(layout.activity(in: main, workspaces: workspaces, terminals: terminals, connected: true), .waiting)
        XCTAssertNil(layout.activity(in: work, workspaces: workspaces, terminals: terminals, connected: true))
    }
    func testSwipeFollowsFingersAndCommitsOnReleaseWithEitherScrollPreference() {
        for inverted in [false, true] {
            let sign: CGFloat = inverted ? -1 : 1
            for deviceX in [CGFloat(-1), CGFloat(1)] {
                var gesture = SidebarSwipeGesture()
                gesture.update(x: deviceX * 30 * sign, y: 2 * sign, timestamp: 1, isDirectionInvertedFromDevice: inverted)
                XCTAssertEqual(gesture.translation, -deviceX * 30)
                gesture.update(x: deviceX * 50 * sign, y: 2 * sign, timestamp: 1.05, isDirectionInvertedFromDevice: inverted)
                XCTAssertEqual(gesture.translation, -deviceX * 80)
                XCTAssertEqual(gesture.destination(width: 260, timestamp: 1.06), deviceX > 0 ? 1 : -1)
            }
        }
    }
    func testVerticalScrollAndSmallMotionsDoNotSwitchSpaces() {
        var gesture = SidebarSwipeGesture()
        gesture.update(x: 3, y: 25, timestamp: 1)
        gesture.update(x: 100, y: 2, timestamp: 1.02)
        XCTAssertFalse(gesture.isHorizontal)
        XCTAssertNil(gesture.destination(width: 260, timestamp: 1.03))
        gesture = SidebarSwipeGesture()
        gesture.update(x: 6, y: 2, timestamp: 1)
        XCTAssertFalse(gesture.isHorizontal)
        XCTAssertEqual(gesture.translation, 0)
        XCTAssertNil(gesture.destination(width: 260, timestamp: 1.01))
    }
    func testShortSlowDragReturnsButQuickFlickCommits() {
        var slow = SidebarSwipeGesture()
        slow.update(x: 15, y: 0, timestamp: 1)
        slow.update(x: 20, y: 0, timestamp: 1.3)
        XCTAssertNil(slow.destination(width: 260, timestamp: 1.31))
        var fast = SidebarSwipeGesture()
        fast.update(x: 15, y: 0, timestamp: 1)
        fast.update(x: 20, y: 0, timestamp: 1.02)
        XCTAssertEqual(fast.destination(width: 260, timestamp: 1.03), 1)
        XCTAssertNil(fast.destination(width: 260, timestamp: 1.3))
    }
    func testReversingBackCancelsAndLatestDirectionWins() {
        var gesture = SidebarSwipeGesture()
        gesture.update(x: 95, y: 0, timestamp: 1)
        gesture.update(x: -90, y: 0, timestamp: 1.2)
        XCTAssertNil(gesture.destination(width: 260, timestamp: 1.3))
        gesture.update(x: -90, y: 0, timestamp: 1.4)
        XCTAssertEqual(gesture.destination(width: 260, timestamp: 1.6), -1)
    }
    func testReversingVelocityCancelsInsteadOfSwitchingOppositeToTheVisiblePage() {
        var gesture = SidebarSwipeGesture()
        gesture.update(x: 100, y: 0, timestamp: 1)
        gesture.update(x: -25, y: 0, timestamp: 1.01)
        XCTAssertLessThan(gesture.translation, 0)
        XCTAssertNil(gesture.destination(width: 260, timestamp: 1.02))
    }
    func testHorizontalLockSurvivesVerticalJitterAndEdgesResist() {
        var gesture = SidebarSwipeGesture()
        gesture.update(x: 20, y: 1, timestamp: 1)
        gesture.update(x: 60, y: 100, timestamp: 1.1)
        XCTAssertTrue(gesture.isHorizontal)
        XCTAssertEqual(gesture.destination(width: 260, timestamp: 1.2), 1)
        XCTAssertEqual(SidebarSwipeGesture.resistedTranslation(-500, width: 260, canNavigate: true), -260)
        let edge = SidebarSwipeGesture.resistedTranslation(-100, width: 260, canNavigate: false)
        XCTAssertLessThan(edge, 0)
        XCTAssertGreaterThan(edge, -22)
    }
}
