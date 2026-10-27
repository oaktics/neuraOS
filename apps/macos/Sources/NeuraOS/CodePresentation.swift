import AppKit
import Highlighter

enum CodePresentation {
    static func language(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        if (path as NSString).lastPathComponent == "Dockerfile" {return "dockerfile"}
        return ["swift": "swift", "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
                "ts": "typescript", "tsx": "typescript", "py": "python", "rb": "ruby", "go": "go", "rs": "rust",
                "c": "c", "h": "c", "cpp": "cpp", "hpp": "cpp", "m": "objectivec", "java": "java", "kt": "kotlin",
                "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "ini", "ini": "ini", "sh": "bash", "zsh": "bash",
                "html": "xml", "xml": "xml", "svg": "xml", "css": "css", "scss": "scss", "sql": "sql", "php": "php",
                "md": "markdown", "markdown": "markdown", "lua": "lua", "r": "r", "dart": "dart"] [ext]
    }
}

// A ruler keeps line numbers out of the editable buffer and copied text.
final class CodeLineRuler: NSRulerView {
    weak var editor: NSTextView?
    init(editor: NSTextView, scroll: NSScrollView) {
        self.editor = editor
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 52
    }
    required init(coder: NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else {return}
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let text = editor.string as NSString
        let visible = manager.glyphRange(forBoundingRect: editor.visibleRect, in: container)
        if visible.length == 0 {
            ("1" as NSString).draw(at: NSPoint(x: ruleThickness - 16, y: editor.textContainerOrigin.y), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let first = manager.characterIndexForGlyph(at: visible.location)
        var number = (text.substring(to: first).filter {$0 == "\n"}).count + 1
        manager.enumerateLineFragments(forGlyphRange: visible) { [self] lineRect, _, _, glyphRange, _ in
            let index = manager.characterIndexForGlyph(at: glyphRange.location)
            if index == 0 || text.character(at: index - 1) == 10 {
                let label = "\(number)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
                let y = lineRect.minY + editor.textContainerOrigin.y - editor.visibleRect.minY
                label.draw(at: NSPoint(x: ruleThickness - 8 - label.size(withAttributes: attributes).width, y: y), withAttributes: attributes)
            }
            let chars = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            number += text.substring(with: chars).filter {$0 == "\n"}.count
        }
    }
}

actor CodeHighlighter {
    static let shared = CodeHighlighter()
    private let highlighter = Highlighter()
    func highlight(_ text: String, language: String, dark: Bool) -> NSAttributedString? {
        // Keep very large buffers responsive; they retain editing, search and line numbers.
        guard text.utf16.count <= 150_000, let highlighter else {return nil}
        _ = highlighter.setTheme(dark ? "atom-one-dark" : "atom-one-light", withFont: "Menlo-Regular", ofSize: 12)
        return highlighter.highlight(text, as: language)
    }
}
