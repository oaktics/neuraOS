import Foundation
import WebKit

/// Virtual URLs expose only files inside this preview's workspace. No file://
/// access is granted to WebKit, and document links open in native file tabs.
final class WorkspaceMarkdownResources: NSObject, WKURLSchemeHandler {
    static let scheme = "neura-workspace"
    let root: URL
    init(root: URL) {self.root = root.resolvingSymlinksInPath().standardizedFileURL}

    static func baseURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme; components.host = "local"; components.path = "/" + path
        return components.url
    }

    func fileURL(for url: URL) throws -> URL {
        guard url.scheme == Self.scheme, url.host == "local", url.user == nil, url.password == nil, url.port == nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        let path = String(url.path.dropFirst())
        let file = try FilePresentation.previewURL(root: root.path, path: path)
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        return file
    }

    func relativePath(for url: URL) throws -> String {
        String(try fileURL(for: url).path.dropFirst(root.path.count + 1))
    }

    func image(for url: URL) throws -> (Data, String) {
        let file = try fileURL(for: url)
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                     "webp": "image/webp", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff",
                     "heic": "image/heic", "avif": "image/avif"]
        guard let type = types[file.pathExtension.lowercased()],
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20 * 1024 * 1024 else {
            throw CocoaError(.fileReadNoPermission)
        }
        let data = try Data(contentsOf: file)
        guard data.count <= 20 * 1024 * 1024 else {throw CocoaError(.fileReadTooLarge)}
        return (data, type)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url else {throw CocoaError(.fileReadInvalidFileName)}
            let (data, type) = try image(for: url)
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {urlSchemeTask.didFailWithError(error)}
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
