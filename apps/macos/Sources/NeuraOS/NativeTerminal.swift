import SwiftUI
import AppKit
import SwiftTerm

/// Cmd-V is a terminal paste action; Codex needs Ctrl-V to read clipboard images.
class NativeTerminalView: TerminalView {
    var provider = "shell"
    private var darkAppearance: Bool?
    var acceptsFileInput: () -> Bool = { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFileInput() && Self.filePasteText(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !draggingEntered(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard pasteFiles(from: sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        return true
    }

    static func filePasteText(from clipboard: NSPasteboard) -> String? {
        guard let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
        // Never let a filename inject terminal control characters or a submit key.
        guard urls.allSatisfy({ $0.isFileURL && !$0.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { return nil }
        return urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ") + " "
    }

    @discardableResult
    func pasteFiles(from clipboard: NSPasteboard) -> Bool {
        guard acceptsFileInput(), let text = Self.filePasteText(from: clipboard) else { return false }
        let input = getTerminal().bracketedPasteMode ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
        send(source: getTerminal(), data: Array(input.utf8)[...])
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    func updateAppearanceColors() {
        // AppKit can notify us during TerminalView initialization.
        guard terminal != nil else {return}
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard darkAppearance != dark else {return}
        darkAppearance = dark
        // SwiftTerm stores concrete RGB defaults and cached text attributes.
        // A dynamic NSColor alone does not refresh those when appearance changes.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeForegroundColor = NSColor.labelColor.usingColorSpace(.deviceRGB)!
            nativeBackgroundColor = NSColor(white: dark ? 0.105 : 0.985, alpha: 1)
        }
        colorChanged(source: getTerminal(), idx: nil)
        needsDisplay = true
    }

    override func paste(_ sender: Any) {
        if NSPasteboard.general.availableType(from: [.fileURL]) != nil {
            pasteFiles(from: .general)
            return
        }
        if !pasteImage(from: .general) { super.paste(sender) }
    }

    @discardableResult
    func pasteImage(from clipboard: NSPasteboard) -> Bool {
        if provider == "codex", clipboard.availableType(from: [.png, .tiff]) != nil {
            // Send a key, not bracketed-paste text. Codex reads the local clipboard.
            send(source: getTerminal(), data: [0x16][...])
            return true
        }
        return false
    }
}

/// Renderer only. The UI never owns a PTY or starts a subprocess.
struct NativeTerminal: NSViewRepresentable {
    let terminal: TerminalRecord
    let api: DaemonClient
    let visible: Bool
    let onError: (Error) -> Void
    func makeCoordinator() -> Coordinator {Coordinator(terminal: terminal, api: api, onError: onError)}
    func makeNSView(context: Context) -> TerminalView {
        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.provider = terminal.provider
        view.updateAppearanceColors()
        view.terminalDelegate = context.coordinator
        context.coordinator.view = view
        view.acceptsFileInput = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.running && coordinator.visible && coordinator.caughtUp
        }
        context.coordinator.desiredSize = (view.getTerminal().cols, view.getTerminal().rows)
        context.coordinator.setVisible(visible)
        context.coordinator.start()
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.running = terminal.status == "running"
        context.coordinator.setVisible(visible)
    }
    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {coordinator.stop(); view.terminalDelegate = nil}
    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        weak var view: TerminalView?
        let terminal: TerminalRecord; let api: DaemonClient; let onError: (Error) -> Void
        var polling: Task<Void, Never>?
        var delay: Task<Void, Never>?
        var running = true; var cursor = 0; var pendingInput = ""; var pendingSize: (Int, Int)?; var desiredSize: (Int, Int)?
        var visible = false
        var applying = false; var caughtUp = false; var reportedError = false
        init(terminal: TerminalRecord, api: DaemonClient, onError: @escaping (Error) -> Void) {self.terminal = terminal; self.api = api; self.onError = onError; self.running = terminal.status == "running"}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard !applying, newCols >= 20, newRows >= 5 else {return}
            desiredSize = (min(400, newCols), min(200, newRows))
            if caughtUp && visible {pendingSize = desiredSize}
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard running, applying || (visible && caughtUp) else {return}
            // Reply sequences from the emulator use the same ordered channel as keystrokes.
            pendingInput += String(decoding: data, as: UTF8.self)
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") else {return}
            NSWorkspace.shared.open(url)
        }
        func stop() {
            setVisible(false)
            delay?.cancel()
            polling?.cancel()
            polling = nil
        }
        func setVisible(_ value: Bool) {
            view?.isHidden = !value
            guard visible != value else {return}
            visible = value
            if value {
                delay?.cancel()
                if caughtUp {pendingSize = desiredSize}
                focusIfVisible()
            } else {
                pendingSize = nil
                if let view, view.window?.firstResponder === view {view.window?.makeFirstResponder(nil)}
            }
        }
        private func focusIfVisible() {
            // SwiftUI may not have attached the view to its window yet.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.visible, self.caughtUp, let view = self.view else {return}
                view.window?.makeFirstResponder(view)
            }
        }
        func apply(_ output: TerminalOutput, to view: TerminalView) {
            applying = true
            for chunk in output.chunks {
                if let cols = chunk.cols, let rows = chunk.rows {view.getTerminal().resize(cols: cols, rows: rows)}
                if !chunk.data.isEmpty {view.feed(text: chunk.data)}
            }
            applying = false; cursor = output.cursor
            if !caughtUp && !output.more {
                caughtUp = true
                if visible, let size = desiredSize {applying = true; view.getTerminal().resize(cols: size.0, rows: size.1); applying = false; pendingSize = size}
                focusIfVisible()
            }
            if visible && !output.chunks.isEmpty {view.needsDisplay = true}
        }
        private func pause(milliseconds: Int) async {
            guard !Task.isCancelled else {return}
            let wait = Task<Void, Never> {try? await Task.sleep(for: .milliseconds(milliseconds))}
            // Cancelling this delay wakes a newly selected terminal immediately.
            delay = wait
            await withTaskCancellationHandler {await wait.value} onCancel: {wait.cancel()}
            delay = nil
        }
        func start() {
            guard polling == nil else {return}
            polling = Task { [weak self] in
                guard let self else {return}
                while !Task.isCancelled {
                    do {
                        if running, !pendingInput.isEmpty {
                            let input = String(pendingInput.prefix(8192)); pendingInput = String(pendingInput.dropFirst(8192))
                            let _: OK = try await api.command(["type": "terminal.input", "terminalId": terminal.id, "clientId": api.clientId, "data": input])
                        }
                        if running, visible, caughtUp, let size = pendingSize {
                            pendingSize = nil
                            let _: OK = try await api.command(["type": "terminal.resize", "terminalId": terminal.id, "clientId": api.clientId, "cols": size.0, "rows": size.1])
                        }
                        let output: TerminalOutput = try await api.get("v1/terminals/\(terminal.id)/output", query: ["after": String(cursor)])
                        guard !Task.isCancelled, let view else {return}
                        apply(output, to: view)
                        reportedError = false
                        await pause(milliseconds: output.more ? 10 : visible ? 60 : 500)
                    } catch {
                        applying = false
                        if visible, !reportedError, !(error is CancellationError) {reportedError = true; onError(error)}
                        await pause(milliseconds: 2000)
                    }
                }
            }
        }
    }
}
