import Foundation

// Bound the complete HTTP envelope, not just result count. Keep headroom under
// the daemon's 12 MiB limit, including tabs, JSON escaping and base64 expansion.
enum BrowserResultBatch {
    static let byteLimit = 10 * 1024 * 1024
    struct Batch {let data: Data; let ids: Set<String>}
    static func make(nativeId: String, tabs: [[String: Any]], results: [[String: Any]], limit: Int = byteLimit) throws -> Batch {
        let base: [String: Any] = ["nativeId":nativeId,"tabs":tabs,"results":[]]
        let overhead = try JSONSerialization.data(withJSONObject:base).count
        guard overhead + 256 <= limit else {throw BrowserAutomationError(code:"browser_registry_too_large")}
        var selected: [[String: Any]] = [], ids = Set<String>(), bytes = overhead
        for original in results.prefix(32) {
            guard let id = original["id"] as? String else {continue}
            var result = original
            var size = try JSONSerialization.data(withJSONObject:result).count
            if overhead + size > limit {
                let image = (result["result"] as? [String: Any])?["data"] is String
                result = ["id":id,"error":image ? "browser_image_too_large" : "browser_result_too_large"]
                size = try JSONSerialization.data(withJSONObject:result).count
            }
            let separator = selected.isEmpty ? 0 : 1
            guard bytes + separator + size <= limit else {break}
            selected.append(result); ids.insert(id); bytes += separator + size
        }
        let data = try JSONSerialization.data(withJSONObject:["nativeId":nativeId,"tabs":tabs,"results":selected])
        assert(data.count <= limit)
        return Batch(data:data,ids:ids)
    }
}
