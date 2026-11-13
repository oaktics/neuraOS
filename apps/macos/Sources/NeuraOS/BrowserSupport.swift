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

struct BrowserVisit: Codable, Equatable {
    var url: String
    var title: String
    var last: Date
    var count: Int
}

/// Pages visited in the built-in browser, kept on this Mac for the command bar.
@MainActor final class BrowserHistory {
    static let shared = BrowserHistory()
    static let limit = 3000
    private(set) var visits: [String: BrowserVisit] = [:]
    private let file: URL?
    private var saving: Task<Void, Never>?

    init(file: URL? = BrowserHistory.defaultFile) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([BrowserVisit].self, from: data) {
            visits = Dictionary(saved.map {($0.url, $0)}, uniquingKeysWith: {first, _ in first})
        }
    }

    nonisolated static var defaultFile: URL? {
        let root = Bundle.main.object(forInfoDictionaryKey: "NeuraDataDirectory") as? String
            ?? NSHomeDirectory() + "/Library/Application Support/neuraOS/Developer"
        return URL(fileURLWithPath: root).appendingPathComponent("browser-history.json")
    }

    func record(_ address: String, title: String, at date: Date = Date()) {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !address.hasPrefix(BrowserInput.searchTemplate) else {return}
        var visit = visits[address] ?? BrowserVisit(url: address, title: title, last: date, count: 0)
        // Several state callbacks describe one page load.
        if visit.count == 0 || date.timeIntervalSince(visit.last) > 10 {visit.count += 1}
        if !title.isEmpty {visit.title = title}
        visit.last = date
        visits[address] = visit
        if visits.count > Self.limit {
            for stale in visits.values.sorted(by: {$0.last < $1.last}).prefix(visits.count - Self.limit) {visits.removeValue(forKey: stale.url)}
        }
        scheduleSave()
    }

    func clear() {visits = [:]; scheduleSave()}

    /// Title prefix, then title, host and address matches; recent and frequent pages first within a rank.
    func search(_ query: String, limit: Int = 6) -> [BrowserVisit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ranked: [(BrowserVisit, Int)] = visits.values.compactMap {visit in
            if needle.isEmpty {return (visit, 0)}
            let title = visit.title.lowercased(), host = BrowserInput.displayHost(visit.url).lowercased()
            if host.hasPrefix(needle) {return (visit, 4)}
            if title.hasPrefix(needle) {return (visit, 3)}
            if title.contains(needle) || host.contains(needle) {return (visit, 2)}
            if visit.url.lowercased().contains(needle) {return (visit, 1)}
            return nil
        }
        return ranked.sorted {
            if $0.1 != $1.1 {return $0.1 > $1.1}
            if $0.0.last != $1.0.last {return $0.0.last > $1.0.last}
            return $0.0.url < $1.0.url
        }.prefix(limit).map(\.0)
    }

    private func scheduleSave() {
        guard let file, saving == nil else {return}
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else {return}
            self.saving = nil
            let snapshot = Array(self.visits.values)
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else {return}
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }.value
        }
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

/// A saved destination shared by every worktree of one project. Closing its tab
/// unloads the page; the pin itself stays until the user removes it.
struct BrowserPin: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var url: String
    var title: String
}

@MainActor final class BrowserPins: ObservableObject {
    static let shared = BrowserPins()
    // Bumped on every change; the lists themselves are filled lazily while views read them.
    @Published private var revision = 0
    private var pins: [String: [BrowserPin]] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {self.defaults = defaults}

    func list(_ projectId: String) -> [BrowserPin] {
        if let loaded = pins[projectId] {return loaded}
        let saved = defaults.data(forKey: key(projectId)).flatMap {try? JSONDecoder().decode([BrowserPin].self, from: $0)} ?? []
        pins[projectId] = saved
        return saved
    }

    func pin(_ id: String, in projectId: String) -> BrowserPin? {list(projectId).first {$0.id == id}}

    @discardableResult
    func add(url: String, title: String, to projectId: String) -> BrowserPin {
        var current = list(projectId)
        if let existing = current.first(where: {$0.url == url}) {return existing}
        let pin = BrowserPin(url: url, title: title.isEmpty ? BrowserInput.displayHost(url) : title)
        current.append(pin)
        save(current, projectId)
        return pin
    }

    func update(_ id: String, in projectId: String, url: String, title: String) {
        var current = list(projectId)
        guard let index = current.firstIndex(where: {$0.id == id}) else {return}
        current[index].url = url
        if !title.isEmpty {current[index].title = title}
        save(current, projectId)
    }

    func remove(_ id: String, from projectId: String) {
        save(list(projectId).filter {$0.id != id}, projectId)
    }

    func move(_ id: String, before targetId: String?, in projectId: String) {
        var current = list(projectId)
        guard id != targetId, let source = current.firstIndex(where: {$0.id == id}) else {return}
        let pin = current.remove(at: source)
        let destination = targetId.flatMap {target in current.firstIndex(where: {$0.id == target})} ?? current.endIndex
        current.insert(pin, at: destination)
        save(current, projectId)
    }

    private func key(_ projectId: String) -> String {"browserPins.\(projectId)"}
    private func save(_ value: [BrowserPin], _ projectId: String) {
        pins[projectId] = value
        revision += 1
        if let data = try? JSONEncoder().encode(value) {defaults.set(data, forKey: key(projectId))}
    }
}
