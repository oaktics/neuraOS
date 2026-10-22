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
        print("Legacy and current daemon feature contracts passed")
    }
}
