import AppKit
import Highlighter
import MarkdownEngine
import SwiftUI

/// How a Markdown file is shown. The choice is shared by every Markdown tab.
enum MarkdownMode: String, CaseIterable, Identifiable {
    /// Styled while typing: the Markdown syntax is hidden except around the caret.
    case rich
    /// The plain text editor used for every other file.
    case source
    /// Read-only GitHub rendering.
    case preview
    var id: String {rawValue}
    var title: String {self == .rich ? "リッチテキスト" : self == .source ? "Markdownソース" : "プレビュー"}
    static let storageKey = "file.markdownMode"
    static func stored(_ raw: String) -> MarkdownMode {MarkdownMode(rawValue: raw) ?? .rich}
}

/// Where a link clicked in a Markdown document leads.
enum MarkdownLinkTarget: Equatable {
    case file(String)
    /// A `[[note]]` that does not exist yet: the path it would be created at.
    case create(String)
    case none
}

enum MarkdownLinks {
    private static let skippedDirectories: Set<String> = ["node_modules", "target", "build", "dist", "Pods", "DerivedData"]
    static let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "bmp", "tiff"]

    /// Joins and normalizes a workspace-relative path. Nil when it would leave the workspace.
    static func join(_ base: String, _ relative: String) -> String? {
        var parts: [Substring] = []
        for part in (base.isEmpty ? relative : base + "/" + relative).split(separator: "/") where part != "." {
            if part == ".." {
                guard !parts.isEmpty else {return nil}
                parts.removeLast()
            } else {parts.append(part)}
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    private static func directory(of path: String) -> String {(path as NSString).deletingLastPathComponent}

    private static func file(_ path: String?, root: String) -> URL? {
        guard let path, let url = try? FilePresentation.previewURL(root: root, path: path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {return nil}
        return url
    }

    /// A path written in the document (`./a.png`, `../b/c.md`, `/docs/d.md`), as a workspace-relative path.
    static func relative(_ reference: String, from path: String, root: String) -> String? {
        let plain = String(reference.trimmingCharacters(in: .whitespaces).prefix {$0 != "#" && $0 != "?"})
        guard !plain.isEmpty, URL(string: plain)?.scheme == nil, let decoded = plain.removingPercentEncoding else {return nil}
        let joined = decoded.hasPrefix("/") ? join("", decoded) : join(directory(of: path), decoded)
        return file(joined, root: root) == nil ? nil : joined
    }

    /// Resolves the name in `[[name]]` the way Obsidian does: beside the note, then anywhere in the folder.
    static func resolveWiki(_ target: String, from path: String, root: String) -> MarkdownLinkTarget {
        var name = String(target.prefix {$0 != "#" && $0 != "|"}).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("\0") else {return .none}
        if (name as NSString).pathExtension.isEmpty {name += ".md"}
        let here = directory(of: path)
        for candidate in [join(here, name), join("", name)] where file(candidate, root: root) != nil {
            return .file(candidate!)
        }
        if let found = find(named: (name as NSString).lastPathComponent, root: root) {return .file(found)}
        // New notes are created next to the note that links to them.
        guard !name.contains("/"), !name.hasPrefix("."), let created = join(here, name) else {return .none}
        return .create(created)
    }

    /// The shallowest file with this name anywhere in the workspace.
    static func find(named name: String, root: String, limit: Int = 50_000) -> String? {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants, .producesRelativePathURLs]) else {return nil}
        var best: String?, seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > limit {break}
            if skippedDirectories.contains(url.lastPathComponent),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walker.skipDescendants(); continue
            }
            guard url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame else {continue}
            let relative = url.relativePath
            if best == nil || relative.split(separator: "/").count < best!.split(separator: "/").count {best = relative}
        }
        return best
    }

    /// Stores a pasted or dropped image beside the note and returns the Markdown path to it.
    static func saveImage(_ data: Data, named name: String, beside path: String, root: String, now: Date = Date()) throws -> String {
        guard data.count <= 20 * 1024 * 1024 else {throw CocoaError(.fileWriteOutOfSpace)}
        let ext = (name as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext) else {throw CocoaError(.fileWriteUnsupportedScheme)}
        var stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        // Pasted screenshots have no name of their own.
        if stem.isEmpty || stem == "image" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
            stem = "image-" + formatter.string(from: now)
        }
        for index in 1...1000 {
            let file = (index == 1 ? stem : "\(stem)-\(index)") + "." + ext
            guard let relative = join(directory(of: path), file) else {break}
            let url = try ExplorerFiles.target(root: root, path: relative, mustExist: false)
            if FileManager.default.fileExists(atPath: url.path) {continue}
            try data.write(to: url, options: .withoutOverwriting)
            return file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// PNG data for an image on the pasteboard. Nil when the pasteboard also carries text, which then pastes as text.
    static func pastedImage(_ pasteboard: NSPasteboard) -> Data? {
        guard pasteboard.string(forType: .string) == nil, pasteboard.string(forType: .fileURL) == nil else {return nil}
        if let png = pasteboard.data(forType: .png) {return png}
        guard let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else {return nil}
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Shows `![alt](path)` and `![[name]]` images that live in the workspace. Remote images stay as links.
struct WorkspaceImageProvider: EmbeddedImageProvider {
    let root: String
    let path: String

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        let relative = MarkdownLinks.relative(reference.name, from: path, root: root)
            ?? (reference.name.contains("/") ? nil : MarkdownLinks.find(named: reference.name, root: root))
        guard let relative, MarkdownLinks.imageExtensions.contains((relative as NSString).pathExtension.lowercased()),
              let url = try? FilePresentation.previewURL(root: root, path: relative),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20 * 1024 * 1024 else {return nil}
        return NSImage(contentsOf: url)
    }

    func fingerprint() -> AnyHashable {root + "\n" + path}
}

/// Code blocks use the same highlighter and palette as the plain editor.
final class MarkdownCodeHighlighter: SyntaxHighlighter, @unchecked Sendable {
    static let shared = MarkdownCodeHighlighter()
    /// Posted when the app switches between light and dark, so cached code colors are rebuilt.
    static let appearanceChanged = Notification.Name("neuraos.markdown.codeAppearanceChanged")
    private let lock = NSLock()
    private let highlighter = Highlighter()
    private var theme = ""

    private var dark: Bool {NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua}
    func codeFont(size: CGFloat) -> NSFont {.monospacedSystemFont(ofSize: size, weight: .regular)}
    // Opaque: the engine paints this behind both the block and its text, and a translucent color would show twice.
    func backgroundColor() -> NSColor {dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.955, alpha: 1)}
    var appearanceDidChangeNotification: Notification.Name? {Self.appearanceChanged}

    func highlight(code: String, language: String?) -> NSAttributedString? {
        guard code.utf16.count <= 50_000, let highlighter, let language = language?.lowercased(), !language.isEmpty else {return nil}
        let wanted = dark ? "atom-one-dark" : "atom-one-light"
        lock.lock(); defer {lock.unlock()}
        if theme != wanted {
            _ = highlighter.setTheme(wanted, withFont: "Menlo-Regular", ofSize: 12)
            theme = wanted
        }
        let aliases = ["js": "javascript", "ts": "typescript", "sh": "bash", "zsh": "bash", "shell": "bash", "yml": "yaml",
                       "py": "python", "rb": "ruby", "rs": "rust", "html": "xml", "objc": "objectivec", "kt": "kotlin"]
        guard let colored = highlighter.highlight(code, as: aliases[language] ?? language) else {return nil}
        // Only the token colors are wanted: the block draws its own background and font.
        let result = NSMutableAttributedString(attributedString: colored)
        result.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// Line-level formatting the engine has no command for: back to body text, and check lists.
enum MarkdownLineEdit {
    enum Style {case body, checklist}

    /// Leading whitespace, the block marker (heading, quote, bullet, number, checkbox), and the rest.
    static func parts(_ line: String) -> (indent: Substring, marker: Substring, content: Substring) {
        let indent = line.prefix {$0 == " " || $0 == "\t"}
        let rest = line.dropFirst(indent.count)
        let patterns = [#"^[-*+] \[[ xX]\] "#, #"^#{1,6} "#, #"^(> ?)+"#, #"^[-*+] "#, #"^\d{1,9}[.)] "#]
        for pattern in patterns {
            if let range = rest.range(of: pattern, options: .regularExpression) {return (indent, rest[range], rest[range.upperBound...])}
        }
        return (indent, "", rest)
    }

    static func isChecklist(_ line: String) -> Bool {parts(line).marker.contains("[")}

    /// Restyles whole lines. A selection made only of check items is turned back into body text.
    static func restyle(_ text: String, to style: Style) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let filled = lines.filter {!$0.trimmingCharacters(in: .whitespaces).isEmpty}
        let uncheck = style == .checklist && !filled.isEmpty && filled.allSatisfy(isChecklist)
        return lines.enumerated().map {index, line in
            let (indent, _, content) = parts(line)
            // Blank lines inside a selection stay blank; a lone empty line still becomes a check item.
            if line.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 {return line}
            switch style {
            case .body: return String(content)
            case .checklist: return String(indent) + (uncheck ? "" : "- [ ] ") + content
            }
        }.joined(separator: "\n")
    }

    /// `[label](url)` for the selected text, or for the address itself when nothing is selected.
    static func link(label: String, url: String) -> String {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "%20")
        let text = label.isEmpty ? address : label.replacingOccurrences(of: "\n", with: " ")
        // Parentheses would end, or unbalance, the destination: addresses such as Wikipedia's carry them.
        let destination = address.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(text.replacingOccurrences(of: "]", with: "\\]"))](\(destination))"
    }
}

/// Marks where the editor sits in the view tree, so the session can reach its text view.
struct MarkdownEditorAnchor: NSViewRepresentable {
    let session: MarkdownEditorSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        session.anchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {session.anchor = view}
}

/// The reading typography of the rich editor: a measured column, generous
/// leading for mixed Japanese and Latin text, and a restrained heading scale.
enum MarkdownTypography {
    static let fontSize: CGFloat = 15
    static let fontName = NSFont.systemFont(ofSize: fontSize).fontName

    static func apply(to configuration: inout MarkdownEditorConfiguration) {
        // About 40 full-width or 75 Latin characters per line; wide tables may use the full width.
        configuration.readingWidth = 660
        configuration.textInsets = TextInsets(horizontal: 32, vertical: 36)
        // Leading near 1.7: kanji need more air between lines than Latin text does.
        // Blank lines of the source stay visible as lines, so paragraphs need little spacing of their own.
        configuration.paragraph = ParagraphStyle(spacingFactor: 0.12, lineHeightExtraSpacing: 7)
        configuration.lists.extraLineHeight = 4
        configuration.blockquote.extraLineHeight = 7
        // A major-third-like scale; small headings never drop below the body size.
        configuration.headings = HeadingStyle(fontMultipliers: [1.8, 1.42, 1.2, 1.06, 1.0, 1.0],
                                              topSpacingEm: [0.3, 0.45, 0.4, 0.3, 0.25, 0.25])
        configuration.codeBlock = CodeBlockStyle(fontSizeScale: 0.87, paragraphSpacing: 6, horizontalIndent: 14)
        configuration.theme.link = .controlAccentColor
        configuration.theme.headingMarker = .tertiaryLabelColor
        configuration.theme.strikethroughColor = .secondaryLabelColor
    }
}

/// Per-tab editor setup and the channel the file pane uses to drive it
/// (formatting commands and find), kept apart from other open editors.
@MainActor final class MarkdownEditorSession: ObservableObject {
    enum Format: String, CaseIterable {case bold, italic, strikethrough, inlineCode, heading, bulletList, numberedList, quote, codeBlock, rule}

    private let id = UUID().uuidString
    let configuration: MarkdownEditorConfiguration
    @Published var matchCount = 0
    /// Whether the caret or selection is in bold / italic text, for the toolbar's pressed state.
    @Published var bold = false
    @Published var italic = false
    private var observers: [NSObjectProtocol] = []

    private func name(_ suffix: String) -> Notification.Name {Notification.Name("neuraos.markdown.\(id).\(suffix)")}

    init(root: String, path: String) {
        let prefix = "neuraos.markdown.\(id)."
        let name = {(suffix: String) in Notification.Name(prefix + suffix)}
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(
            images: WorkspaceImageProvider(root: root, path: path),
            syntaxHighlighter: MarkdownCodeHighlighter.shared,
            bus: MarkdownEditorBus(
                applyBoldRequest: name(Format.bold.rawValue), applyItalicRequest: name(Format.italic.rawValue),
                applyHeadingRequest: name(Format.heading.rawValue), applyStrikethroughRequest: name(Format.strikethrough.rawValue),
                applyInlineCodeRequest: name(Format.inlineCode.rawValue), applyBlockquoteRequest: name(Format.quote.rawValue),
                applyUnorderedListRequest: name(Format.bulletList.rawValue), applyOrderedListRequest: name(Format.numberedList.rawValue),
                applyCodeBlockRequest: name(Format.codeBlock.rawValue), applyHorizontalRuleRequest: name(Format.rule.rawValue),
                selectionBoldDidChange: name("isBold"), selectionItalicDidChange: name("isItalic"),
                findClearHighlights: name("findClear"), findQuery: name("findQuery"), findResults: name("findResults")))
        configuration.extensions = [StrikethroughExtension()]
        MarkdownTypography.apply(to: &configuration)
        self.configuration = configuration
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: name("findResults"), object: nil, queue: .main) { [weak self] note in
                let count = note.userInfo?["count"] as? Int ?? 0
                MainActor.assumeIsolated {if self?.matchCount != count {self?.matchCount = count}}
            },
            center.addObserver(forName: name("isBold"), object: nil, queue: .main) { [weak self] note in
                let value = note.userInfo?["isBold"] as? Bool ?? false
                MainActor.assumeIsolated {if self?.bold != value {self?.bold = value}}
            },
            center.addObserver(forName: name("isItalic"), object: nil, queue: .main) { [weak self] note in
                let value = note.userInfo?["isItalic"] as? Bool ?? false
                MainActor.assumeIsolated {if self?.italic != value {self?.italic = value}}
            },
        ]
        // The engine publishes typed edits, but an undo or redo changes its text without a word:
        // the document, and with it the file on disk, would keep what was just taken back.
        for change in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(center.addObserver(forName: change, object: nil, queue: .main) { [weak self] note in
                let manager = note.object as? UndoManager
                MainActor.assumeIsolated {self?.publishUndo(of: manager)}
            })
        }
    }

    private func publishUndo(of manager: UndoManager?) {
        guard let manager, let view = textView, view.window != nil,
              view.delegate?.undoManager?(for: view) === manager, !view.hasMarkedText() else {return}
        view.didChangeText()
    }

    deinit {observers.forEach(NotificationCenter.default.removeObserver)}

    weak var anchor: NSView?

    /// The engine's text view for this tab: the nearest one around the anchor.
    private var textView: NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.className.contains("NativeTextView") {return text}
            for child in view.subviews {if let found = find(child) {return found}}
            return nil
        }
        var ancestor = anchor?.superview
        for _ in 0..<4 {
            guard let view = ancestor else {return nil}
            if let found = find(view) {return found}
            ancestor = view.superview
        }
        return nil
    }

    /// The selected text, as the label a new link would get.
    var selectedText: String {
        guard let view = textView else {return ""}
        return (view.string as NSString).substring(with: view.selectedRange())
    }

    /// Typed in through the text view, so undo, styling and the document binding all follow.
    private func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
        guard let view = textView, view.isEditable else {return}
        view.window?.makeFirstResponder(view)
        view.insertText(text, replacementRange: range)
        if let select {view.setSelectedRange(select)}
    }

    func restyleLines(_ style: MarkdownLineEdit.Style) {
        guard let view = textView else {return}
        let text = view.string as NSString
        var lines = text.lineRange(for: view.selectedRange())
        // The line break after the last line is not part of what is restyled.
        if lines.length > 0, text.character(at: NSMaxRange(lines) - 1) == 10 {lines.length -= 1}
        let updated = MarkdownLineEdit.restyle(text.substring(with: lines), to: style)
        let length = (updated as NSString).length
        let single = !updated.contains("\n")
        replace(lines, with: updated, select: single ? NSRange(location: lines.location + length, length: 0) : NSRange(location: lines.location, length: length))
    }

    func insertLink(_ url: String) {
        guard let view = textView, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {return}
        replace(view.selectedRange(), with: MarkdownLineEdit.link(label: selectedText, url: url))
    }

    func apply(_ format: Format, level: Int? = nil) {
        NotificationCenter.default.post(name: name(format.rawValue), object: nil, userInfo: level.map {["level": $0]})
    }

    func find(_ query: String, index: Int) {
        guard !query.isEmpty else {clearFind(); return}
        NotificationCenter.default.post(name: name("findQuery"), object: nil, userInfo: ["query": query, "currentIndex": index])
    }

    func clearFind() {
        matchCount = 0
        NotificationCenter.default.post(name: name("findClear"), object: nil)
    }
}

/// Notion-style editing of a Markdown file with a native text view. The text
/// stays exactly the Markdown that is on disk: the engine only styles it and
/// hides the syntax away from the caret, so nothing is rewritten on save.
struct MarkdownRichEditor: View {
    @Binding var text: String
    var editable: Bool
    let workspace: Workspace
    let path: String
    @ObservedObject var session: MarkdownEditorSession
    let openFile: (String) -> Void

    var body: some View {
        let root = workspace.path, path = path
        NativeTextViewWrapper(
            text: $text,
            configuration: session.configuration,
            fontName: MarkdownTypography.fontName,
            fontSize: MarkdownTypography.fontSize,
            documentId: workspace.id + "\n" + path,
            parkingKey: workspace.id + "\n" + path,
            isEditable: editable,
            onPasteImage: {pasteboard in
                guard editable, let data = MarkdownLinks.pastedImage(pasteboard),
                      let file = try? MarkdownLinks.saveImage(data, named: "image.png", beside: path, root: root) else {return nil}
                return "![](\(file))"
            },
            fileDrop: EditorFileDrop(
                action: {files, _ in
                    editable && files.allSatisfy {MarkdownLinks.imageExtensions.contains($0.pathExtension.lowercased())} ? .insert : .refuse
                },
                markdown: {files in
                    let lines = files.compactMap {url -> String? in
                        guard let data = try? Data(contentsOf: url),
                              let file = try? MarkdownLinks.saveImage(data, named: url.lastPathComponent, beside: path, root: root) else {return nil}
                        return "![](\(file))"
                    }
                    return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
                },
                handOff: {_ in}),
            onLinkClick: {target in
                switch MarkdownLinks.resolveWiki(target, from: path, root: root) {
                case .file(let file): openFile(file)
                case .create(let file):
                    guard editable, (try? ExplorerFiles.perform(.newFile, root: root, source: "", destination: file)) != nil else {NSSound.beep(); return}
                    openFile(file)
                case .none: NSSound.beep()
                }
            })
            .background(MarkdownEditorAnchor(session: session))
    }
}
