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
    func testHorizontalSwipeTriggersOnlyOnce() {
        var gesture = SidebarSwipeGesture()
        XCTAssertNil(gesture.update(x: -30, y: 2))
        XCTAssertEqual(gesture.update(x: -40, y: 2), 1)
        XCTAssertNil(gesture.update(x: -100, y: 0))
        XCTAssertTrue(gesture.isHorizontal)
        gesture = SidebarSwipeGesture()
        XCTAssertEqual(gesture.update(x: 70, y: 0), -1)
    }
    func testSwipeDirectionIsIndependentOfNaturalScrollingPreference() {
        for inverted in [false, true] {
            let sign: CGFloat = inverted ? -1 : 1
            for deviceX in [CGFloat(-1), CGFloat(1)] {
                var gesture = SidebarSwipeGesture()
                XCTAssertNil(gesture.update(x: deviceX * 30 * sign, y: 2 * sign, isDirectionInvertedFromDevice: inverted))
                XCTAssertEqual(gesture.update(x: deviceX * 40 * sign, y: 2 * sign, isDirectionInvertedFromDevice: inverted), deviceX < 0 ? 1 : -1)
                XCTAssertNil(gesture.update(x: deviceX * 100 * sign, y: 0, isDirectionInvertedFromDevice: inverted))
            }
            var vertical = SidebarSwipeGesture()
            XCTAssertNil(vertical.update(x: 3 * sign, y: 25 * sign, isDirectionInvertedFromDevice: inverted))
            XCTAssertNil(vertical.update(x: 100 * sign, y: 2 * sign, isDirectionInvertedFromDevice: inverted))
            XCTAssertFalse(vertical.isHorizontal)
        }
    }
    func testVerticalScrollAndSmallMotionsDoNotSwitchSpaces() {
        var gesture = SidebarSwipeGesture()
        XCTAssertNil(gesture.update(x: 3, y: 25))
        XCTAssertNil(gesture.update(x: 100, y: 2))
        XCTAssertFalse(gesture.isHorizontal)
        gesture = SidebarSwipeGesture()
        XCTAssertNil(gesture.update(x: 8, y: 2))
        XCTAssertFalse(gesture.isHorizontal)
    }
}
