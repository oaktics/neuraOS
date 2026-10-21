import SwiftUI
import AppKit
import SwiftTerm

/// Renderer only. The UI never owns a PTY or starts a subprocess.
struct NativeTerminal: NSViewRepresentable {
    let terminal: TerminalRecord
    let api: DaemonClient
    let onError: (Error) -> Void
    func makeCoordinator() -> Coordinator {Coordinator(terminal: terminal, api: api, onError: onError)}
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.nativeForegroundColor = .labelColor
        view.nativeBackgroundColor = NSColor(name: nil) {appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.105, alpha: 1) : NSColor(white: 0.985, alpha: 1)}
        view.terminalDelegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.desiredSize = (view.getTerminal().cols, view.getTerminal().rows)
        context.coordinator.start()
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) {context.coordinator.running = terminal.status == "running"}
    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {coordinator.polling?.cancel(); view.terminalDelegate = nil}
    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        weak var view: TerminalView?
        let terminal: TerminalRecord; let api: DaemonClient; let onError: (Error) -> Void
        var polling: Task<Void, Never>?
        var running = true; var cursor = 0; var pendingInput = ""; var pendingSize: (Int, Int)?; var desiredSize: (Int, Int)?
        var applying = false; var caughtUp = false; var reportedError = false
        init(terminal: TerminalRecord, api: DaemonClient, onError: @escaping (Error) -> Void) {self.terminal = terminal; self.api = api; self.onError = onError}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard !applying, newCols >= 20, newRows >= 5 else {return}
            desiredSize = (min(400, newCols), min(200, newRows))
            if caughtUp {pendingSize = desiredSize}
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard running else {return}
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
        func start() {
            polling = Task { [weak self] in
                guard let self else {return}
                while !Task.isCancelled {
                    do {
                        if running, !pendingInput.isEmpty {
                            let input = String(pendingInput.prefix(8192)); pendingInput = String(pendingInput.dropFirst(8192))
                            let _: OK = try await api.command(["type": "terminal.input", "terminalId": terminal.id, "clientId": api.clientId, "data": input])
                        }
                        if running, caughtUp, let size = pendingSize {
                            pendingSize = nil
                            let _: OK = try await api.command(["type": "terminal.resize", "terminalId": terminal.id, "clientId": api.clientId, "cols": size.0, "rows": size.1])
                        }
                        let output: TerminalOutput = try await api.get("v1/terminals/\(terminal.id)/output", query: ["after": String(cursor)])
                        guard !Task.isCancelled, let view else {return}
                        applying = true
                        for chunk in output.chunks {
                            if let cols = chunk.cols, let rows = chunk.rows {view.getTerminal().resize(cols: cols, rows: rows)}
                            if !chunk.data.isEmpty {view.feed(text: chunk.data)}
                        }
                        applying = false; cursor = output.cursor
                        if !caughtUp && !output.more {
                            caughtUp = true
                            if let size = desiredSize {applying = true; view.getTerminal().resize(cols: size.0, rows: size.1); applying = false; pendingSize = size}
                            view.window?.makeFirstResponder(view)
                        }
                        view.needsDisplay = true
                        reportedError = false
                        try? await Task.sleep(for: .milliseconds(output.more ? 10 : 60))
                    } catch {
                        applying = false
                        if !reportedError, !(error is CancellationError) {reportedError = true; onError(error)}
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
        }
    }
}
