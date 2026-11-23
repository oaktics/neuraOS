import SwiftUI
import AppKit

/// Turns what the user typed into a destination: an address when it looks like
/// one, otherwise a web search. `BrowserModel.navigationURL` stays the strict
/// validator for addresses that arrive from agents and saved state.
enum BrowserInput {
    static let searchTemplate = "https://www.google.com/search?q="
    // `package.json` or `index.ts` is a search here, not a host. Only suffixes that are not
    // real top-level domains are listed: `docs.rs` and `ohmyz.sh` must stay addresses.
    private static let fileSuffixes: Set<String> = [
        "js", "ts", "tsx", "jsx", "mjs", "go", "rb", "c", "h", "cpp", "hpp", "cs", "java", "kt",
        "txt", "json", "yml", "yaml", "toml", "lock", "zsh", "css", "scss", "html", "xml", "sql", "log", "png", "jpg", "pdf"
    ]

    static func isSearch(_ input: String) -> Bool {address(input) == nil && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty}

    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {return nil}
        if let address = address(text) {return address}
        // A scheme we do not load must not be forwarded to a search engine either.
        if text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {return nil}
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let query = text.addingPercentEncoding(withAllowedCharacters: allowed) else {return nil}
        return URL(string: searchTemplate + query)
    }

    /// The address the text names, or nil when it should be searched instead.
    static func address(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "about:blank" {return URL(string: text)}
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {return nil}
        if text.contains("://") {return BrowserModel.navigationURL(text)}
        let authority = String(text.prefix {!"/?#".contains($0)})
        let host = hostPart(authority)
        guard !host.isEmpty, !authority.contains("@") else {return nil}
        let hasPath = authority.count < text.count
        let hasPort = authority.count > host.count
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || isIPv4(host) || host.hasPrefix("[")
        if local {return BrowserModel.navigationURL("http://" + text)}
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.range(of: #"^[^\s:/?#\[\]@]+$"#, options: .regularExpression) != nil,
              let suffix = host.split(separator: ".").last, suffix.count >= 2,
              suffix.rangeOfCharacter(from: .decimalDigits) == nil else {return nil}
        if !hasPath, !hasPort, fileSuffixes.contains(suffix.lowercased()) {return nil}
        return BrowserModel.navigationURL("https://" + text)
    }

    private static func hostPart(_ authority: String) -> String {
        if authority.hasPrefix("["), let end = authority.firstIndex(of: "]") {return String(authority[...end])}
        guard let colon = authority.lastIndex(of: ":") else {return authority}
        let port = authority[authority.index(after: colon)...]
        return !port.isEmpty && port.allSatisfy(\.isNumber) ? String(authority[..<colon]) : authority
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {UInt8($0) != nil}
    }

    /// Short form for tab titles and the address capsule.
    static func displayHost(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host, !host.isEmpty else {return address}
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return url.port.map {"\(name):\($0)"} ?? name
    }
}

/// Page icons by host. Chromium downloads them; this only remembers the result.
@MainActor final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()
    @Published private(set) var revision = 0
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private let directory: URL?

    init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("neuraOS/favicons")) {
        self.directory = directory
    }

    static func key(_ address: String) -> String? {
        guard let host = URL(string: address)?.host?.lowercased(), !host.isEmpty else {return nil}
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func image(for address: String?) -> NSImage? {
        guard let address, let key = Self.key(address) else {return nil}
        if let image = images[key] {return image}
        guard !missing.contains(key) else {return nil}
        if let file = file(key), let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            images[key] = image
            return image
        }
        missing.insert(key)
        return nil
    }

    func store(_ png: Data?, for address: String) {
        guard let key = Self.key(address), let png, let image = NSImage(data: png) else {return}
        images[key] = image
        missing.remove(key)
        revision += 1
        guard let file = file(key) else {return}
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
    }

    private func file(_ key: String) -> URL? {
        let name = key.unicodeScalars.map {CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? String($0) : "_"}.joined()
        return directory?.appendingPathComponent(name + ".png")
    }
}

struct FaviconView: View {
    @ObservedObject private var store = FaviconStore.shared
    let address: String?
    var size: CGFloat = 14
    var fallback = "globe"
    var body: some View {
        if let image = store.image(for: address) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Image(systemName: fallback).font(.system(size: size * 0.85)).frame(width: size, height: size)
        }
    }
}
