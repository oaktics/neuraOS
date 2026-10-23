import XCTest
@testable import NeuraOS

final class FolderlessProjectTests: XCTestCase {
    func testLegacyProjectDecodesAndScratchHasNoFolderCapabilities() throws {
        let project = try JSONDecoder().decode(Project.self, from: Data(#"{"id":"p","name":"Existing","path":"/repo","isGit":true}"#.utf8))
        XCTAssertTrue(project.supportsGit)
        XCTAssertNil(project.folderless)
        let scratch = Workspace(id: "w", projectId: "p", name: "フリー", path: "/managed", branch: "", kind: "scratch")
        XCTAssertFalse(scratch.supportsGit)
        XCTAssertFalse(scratch.hasFolder)
        let folder = Workspace(id: "f", projectId: "p", name: "Folder", path: "/folder", branch: "", kind: "folder")
        XCTAssertFalse(folder.supportsGit)
        XCTAssertTrue(folder.hasFolder)
    }
    func testFolderlessProjectDecodes() throws {
        let project = try JSONDecoder().decode(Project.self, from: Data(#"{"id":"p","name":"Travel","path":"/managed","isGit":false,"folderless":true}"#.utf8))
        XCTAssertEqual(project.folderless, true)
        XCTAssertFalse(project.supportsGit)
    }
}
