import Foundation

@main
struct DaemonCapabilitiesContractTest {
    static func main() throws {
        // Decode the actual client model against old and new v1 wire payloads.
        let legacy = #"{"protocolVersion":1,"hostName":"test","revision":7,"projects":[],"workspaces":[],"terminals":[]}"#
        func decode(_ features: String?, version: Int = 1) throws -> Snapshot {
            var object = try JSONSerialization.jsonObject(with: Data(legacy.utf8)) as! [String: Any]
            object["protocolVersion"] = version
            if let features {object["features"] = try JSONSerialization.jsonObject(with: Data(features.utf8))}
            return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let old = try decode(nil)
        precondition(!old.supportsGitHub, "Old v1 daemons must not enable GitHub")
        for features in ["[]", #"["future-feature"]"#] {
            let unsupported = try decode(features)
            precondition(!unsupported.supportsGitHub)
        }
        let current = try decode(#"["github"]"#)
        precondition(current.supportsGitHub)
        precondition(current.revision == old.revision && current.features != old.features,
                     "Capability changes must be observed even at the same data revision")
        let futureFeature = try decode(#"["future-feature","github"]"#)
        precondition(futureFeature.supportsGitHub)
        let incompatible = try decode(#"["github"]"#, version: 2)
        precondition(!incompatible.supportsGitHub)
        precondition(!old.supportsMultipleTerminals)
        precondition(!current.supportsMultipleTerminals, "The previous GitHub-capable daemon still deduplicates PTYs")
        let multi = try decode(#"["github","terminal.multiple"]"#)
        precondition(multi.supportsMultipleTerminals)
        let incompatibleMulti = try decode(#"["terminal.multiple"]"#, version: 2)
        precondition(!incompatibleMulti.supportsMultipleTerminals)
        let legacyProject = #"{"id":"project","name":"test","path":"/tmp/test","isGit":true}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(legacyProject.utf8))
        precondition(project.worktreeStartup == nil)
        var configured = project
        configured.worktreeStartup = ["codex", "shell"]
        let roundTrip = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(configured))
        precondition(roundTrip.worktreeStartup == ["codex", "shell"])
        let created = try JSONDecoder().decode(CreatedWorkspace.self, from: Data(#"{"id":"workspace","startupErrors":["CLI missing"]}"#.utf8))
        precondition(created.startupErrors == ["CLI missing"])
        let oldCreated = try JSONDecoder().decode(CreatedWorkspace.self, from: Data(#"{"id":"workspace"}"#.utf8))
        precondition(oldCreated.startupErrors == nil)
        // Old preferences must retain their spaces and selections when order is absent.
        let oldLayout = #"{"spaces":[{"id":"main","name":"メイン","selectedWorkspaceId":"w1"},{"id":"work","name":"仕事"}],"activeId":"main","projectSpaces":{"other":"work"}}"#
        var layout = try JSONDecoder().decode(SidebarSpaces.self, from: Data(oldLayout.utf8))
        let projects = ["a", "b", "c", "other"].map {Project(id: $0, name: $0, path: "", isGit: false)}
        precondition(layout.projects(in: "main", from: projects).map(\.id) == ["a", "b", "c"])
        precondition(layout.reorderProject("a", onto: "c", in: "main", projects: projects))
        precondition(layout.projects(in: "main", from: projects).map(\.id) == ["b", "c", "a"])
        precondition(layout.reorderProject("a", onto: "b", in: "main", projects: projects))
        precondition(layout.projects(in: "main", from: projects).map(\.id) == ["a", "b", "c"])
        precondition(layout.reorderProject("c", onto: "a", in: "main", projects: projects))
        precondition(!layout.reorderProject("other", onto: "a", in: "main", projects: projects))
        precondition(!layout.reorderProject("a", onto: "a", in: "main", projects: projects))
        precondition(!layout.reorderProject("deleted", onto: "a", in: "main", projects: projects))
        let restoredLayout = try JSONDecoder().decode(SidebarSpaces.self, from: JSONEncoder().encode(layout))
        precondition(restoredLayout.projects(in: "main", from: projects.reversed()).map(\.id) == ["c", "a", "b"])
        precondition(restoredLayout.active.selectedWorkspaceId == "w1")
        precondition(restoredLayout.projects(in: "work", from: projects).map(\.id) == ["other"])
        let changedProjects = projects.filter {$0.id != "a"} + [Project(id: "new", name: "new", path: "", isGit: false)]
        precondition(restoredLayout.projects(in: "main", from: changedProjects).map(\.id) == ["c", "b", "new"])
        print("Legacy and current daemon feature contracts passed")
    }
}
