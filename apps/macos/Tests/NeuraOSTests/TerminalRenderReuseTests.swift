import XCTest
import AppKit
@testable import SwiftTerm
import MetalKit
@testable import NeuraOS

/// Work-count and equivalence checks for the vendored SwiftTerm Metal renderer.
/// They count rows, never time, so they hold on a loaded machine.
final class TerminalRenderReuseTests: XCTestCase {
    private let esc = "\u{1b}"

    override func tearDown() {
        TerminalView.metalVerifiesRowReuse = false
        TerminalView.metalRowReuseEnabled = true
        super.tearDown()
    }

    @MainActor private final class Fixture {
        let window: NSWindow
        let view: NativeTerminalView
        let metal: MTKView
        var terminal: Terminal {view.getTerminal()}
        var statistics: MetalRenderStatistics {view.metalRenderStatistics ?? MetalRenderStatistics()}

        init() throws {
            _ = NSApplication.shared
            _ = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal device unavailable")
            // Same resource mirroring as TerminalLifecycleTests: SwiftPM leaves the
            // dependency bundle beside the xctest bundle.
            let testBundle = Bundle(for: TerminalRenderReuseTests.self)
            let resources = try XCTUnwrap(testBundle.resourceURL)
            let name = "SwiftTerm_SwiftTerm.bundle"
            let destination = resources.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: testBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name), to: destination)
            }
            // The window is never ordered in; it only gives the Metal layer a backing scale.
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            window.contentView = view
            try view.setUseMetal(true)
            metal = try XCTUnwrap(view.subviews.compactMap {$0 as? MTKView}.first)
        }

        /// Feeds output, waits for SwiftTerm's display pass, then draws one frame.
        /// Returns the renderer work done since the call started; AppKit may add
        /// a draw of its own, which `frames` reports.
        @discardableResult func frame(_ text: String = "", _ change: () -> Void = {}) async throws -> MetalRenderStatistics {
            // Let the previous frame's GPU completion release SwiftTerm's frame gate.
            try await Task.sleep(for: .milliseconds(12))
            let before = statistics
            if !text.isEmpty {view.feed(text: text)}
            change()
            for _ in 0..<80 where terminal.getUpdateRange() != nil {try await Task.sleep(for: .milliseconds(5))}
            // AppKit may already have drawn this frame from the display pass.
            // SwiftTerm refuses a draw while the previous frame is still on the
            // GPU, so retry until one is accepted.
            for _ in 0..<100 where statistics.frames == before.frames {
                metal.draw()
                if statistics.frames == before.frames {try await Task.sleep(for: .milliseconds(10))}
            }
            var delta = statistics
            delta.frames -= before.frames
            delta.rowsRebuilt -= before.rowsRebuilt
            delta.rowsReused -= before.rowsReused
            delta.rowsRepositioned -= before.rowsRepositioned
            delta.glyphsRasterized -= before.glyphsRasterized
            delta.runsShaped -= before.runsShaped
            return delta
        }

        func at(_ row: Int, _ col: Int = 1) -> String {"\u{1b}[\(row);\(col)H"}

        func fill() -> String {
            var out = "\u{1b}[2J\u{1b}[H"
            for row in 1...terminal.rows {
                out += at(row) + "\u{1b}[3\(row % 7 + 1)mline \(row)\u{1b}[0m 日本語 ✅ │ box ─┼─ \u{1b}[4munderlined\u{1b}[0m \u{1b}[48;5;236mcode\u{1b}[0m"
            }
            return out
        }

        /// Draws once and skips when this machine cannot provide a Metal drawable.
        func start() async throws {
            view.feed(text: fill())
            for _ in 0..<80 where terminal.getUpdateRange() != nil {try await Task.sleep(for: .milliseconds(5))}
            for _ in 0..<20 where statistics.frames == 0 {
                metal.draw()
                if statistics.frames == 0 {try await Task.sleep(for: .milliseconds(10))}
            }
            if statistics.frames == 0 {throw XCTSkip("No Metal drawable is available in this environment")}
        }
    }

    @MainActor func testSpinnerUpdateRebuildsOnlyChangedRows() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let rows = fixture.terminal.rows
        try await fixture.frame()
        for index in 0..<20 {
            // The update range spans both rows and everything between them.
            let work = try await fixture.frame(fixture.at(rows - 6) + "✻ Thinking… \(index)s\(esc)[K" + fixture.at(rows) + "status \(index)\(esc)[K")
            XCTAssertEqual(work.rowsRebuilt, 2, "frame \(index)")
            XCTAssertEqual(work.rowsRebuilt + work.rowsReused, rows * work.frames, "frame \(index)")
        }
    }

    @MainActor func testScrollingOutputRebuildsOnlyNewRows() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let rows = fixture.terminal.rows
        var repositioned = 0
        for index in 0..<20 {
            let work = try await fixture.frame(fixture.at(rows) + "\r\nnew line \(index) 日本語 ─")
            // The new bottom row, plus the row the cursor left.
            XCTAssertLessThanOrEqual(work.rowsRebuilt, 2, "frame \(index)")
            XCTAssertEqual(work.rowsRebuilt + work.rowsReused, rows * work.frames, "frame \(index)")
            repositioned += work.rowsRepositioned
        }
        XCTAssertGreaterThan(repositioned, 20 * (rows - 3))
    }

    @MainActor func testUpstreamBehaviourRebuildsWholeRangeWhenReuseIsDisabled() async throws {
        TerminalView.metalRowReuseEnabled = false
        let fixture = try Fixture()
        try await fixture.start()
        let rows = fixture.terminal.rows
        let spinner = try await fixture.frame(fixture.at(rows - 6) + "✻ Thinking…\(esc)[K" + fixture.at(rows) + "status\(esc)[K")
        XCTAssertEqual(spinner.rowsRebuilt, 7)
        let scroll = try await fixture.frame(fixture.at(rows) + "\r\nnew line")
        XCTAssertEqual(scroll.rowsRebuilt, rows)
        XCTAssertEqual(scroll.rowsRepositioned, 0)
    }

    /// Redraw requests that do not come from parsed output (our own show path,
    /// SwiftTerm option changes) keep upstream's meaning: rebuild the range.
    @MainActor func testViewRequestedRefreshRebuildsEveryRow() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let rows = fixture.terminal.rows
        let idle = try await fixture.frame(fixture.at(2) + "x")
        XCTAssertEqual(idle.rowsRebuilt, 1)
        let refreshed = try await fixture.frame {
            fixture.terminal.updateFullScreen()
            fixture.view.synchronizedOutputChanged(source: fixture.terminal, active: false)
        }
        XCTAssertEqual(refreshed.rowsRebuilt, rows)
        // A parser update merged with a pending view request stays forced.
        fixture.terminal.updateFullScreen()
        let merged = try await fixture.frame(fixture.at(3) + "y")
        XCTAssertEqual(merged.rowsRebuilt, rows)
    }

    /// Every reused row is also rebuilt from scratch and compared, across the
    /// view and terminal state changes that alter how an unchanged line is drawn.
    @MainActor func testReusedRowsMatchFreshRebuilds() async throws {
        TerminalView.metalVerifiesRowReuse = true
        let fixture = try Fixture()
        try await fixture.start()
        let view = fixture.view
        let rows = fixture.terminal.rows
        func at(_ row: Int) -> String {fixture.at(row)}
        var reused = 0
        func step(_ text: String = "", _ change: () -> Void = {}, line: UInt = #line) async throws {
            let work = try await fixture.frame(text, change)
            reused += work.rowsReused
            XCTAssertEqual(fixture.statistics.reuseMismatches, 0, "reused rows differ from a rebuild", line: line)
        }
        try await step(at(rows - 6) + "✻ spinner\(esc)[K" + at(rows) + "status\(esc)[K")
        // Scrolling, with wide and combining text entering the screen.
        for index in 0..<8 {try await step(at(rows) + "\r\nscroll \(index) 日本語 🚀 e\u{301} \(esc)[5mblink\(esc)[0m ─│")}
        // Selection changes with and without simultaneous output.
        try await step {view.selectAll()}
        try await step(at(3) + "changed while selected\(esc)[K")
        try await step {view.selectNone()}
        try await step(at(rows) + "\r\nafter selection")
        // Palette, default colors and reverse video change colors of unchanged lines.
        try await step("\(esc)]4;1;rgb:12/34/56\(esc)\\" + at(rows) + "\r\npalette")
        try await step("\(esc)]10;rgb:aa/bb/cc\(esc)\\\(esc)]11;rgb:10/10/30\(esc)\\" + at(2) + "x")
        try await step("\(esc)[?5h" + at(2) + "y")
        try await step("\(esc)[?5l" + at(rows) + "\r\nnormal video")
        try await step {view.selectedTextBackgroundColor = .systemPink}
        try await step {view.updateAppearanceColors(); view.nativeForegroundColor = NSColor(deviceRed: 0.2, green: 0.9, blue: 0.4, alpha: 1)}
        try await step(at(rows) + "\r\nafter color")
        // Scroll regions, line insertion and deletion move lines between rows.
        try await step("\(esc)[5;15r" + at(15) + "\r\nregion scroll\(esc)[r")
        try await step(at(8) + "\(esc)[2L" + at(20) + "\(esc)[3M" + at(rows) + "\r\nedited")
        try await step(at(10) + "\(esc)[K" + at(11) + "\(esc)[2K" + at(rows) + "\r\nerased")
        // DEC double-size lines are never repositioned.
        try await step(at(4) + "\(esc)#6double width" + at(rows) + "\r\nafter double")
        // Scrollback viewing, then new output while scrolled back.
        try await step {view.scrollUp(lines: 5)}
        try await step(at(rows) + "\r\nwhile scrolled back")
        try await step {view.scroll(toPosition: 1)}
        // Alternate screen and back.
        try await step("\(esc)[?1049h\(esc)[2J" + at(2) + "alternate screen")
        try await step(at(3) + "alt line")
        try await step("\(esc)[?1049l")
        try await step(at(rows) + "\r\nback on the normal screen")
        // Hidden terminals keep parsing; showing them draws the current state.
        view.setRenderingVisible(false)
        view.feed(text: at(rows) + "\r\nhidden one\r\nhidden two")
        try await Task.sleep(for: .milliseconds(60))
        view.setRenderingVisible(true)
        try await step()
        // Resize.
        try await step {view.setFrameSize(NSSize(width: 700, height: 500))}
        try await step(at(2) + "after resize\(esc)[K")
        // Blink phase changes, with and without output on other rows.
        try await step(at(5) + "\(esc)[5mblinking\(esc)[0m steady")
        try await step {view.setTextBlinkVisibleForTesting(false)}
        try await step(at(rows) + "\r\nwhile hidden phase")
        try await step {view.setTextBlinkVisibleForTesting(true)}
        try await step(at(rows) + "\r\nlast")
        XCTAssertGreaterThan(reused, 200, "the scenario must exercise the reuse path")
        XCTAssertEqual(fixture.statistics.reuseMismatches, 0)
    }

    private final class CountingTerminalView: NativeTerminalView {
        var displayRequests = 0
        override var needsDisplay: Bool {
            get {super.needsDisplay}
            set {
                if newValue {displayRequests += 1}
                super.needsDisplay = newValue
            }
        }
    }

    @MainActor func testOutputInvalidatesTheTerminalViewOnlyForTheFallbackRenderer() throws {
        _ = try Fixture() // mirrors the shader bundle for the windowless views below
        func displayRequestsForOutput(metal: Bool) throws -> Int {
            let view = CountingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            if metal {try view.setUseMetal(true)}
            XCTAssertEqual(view.isUsingMetalRenderer, metal)
            let record = TerminalRecord(id: "test-only", workspaceId: "test", provider: "shell", status: "running", cols: 100, rows: 30)
            let coordinator = NativeTerminal.Coordinator(terminal: record, api: DaemonClient(), onError: {_ in XCTFail("Unexpected API call")})
            coordinator.view = view
            coordinator.setVisible(true)
            view.displayRequests = 0
            coordinator.apply(TerminalOutput(data: "x", chunks: [TerminalChunk(data: "x", cols: nil, rows: nil)], cursor: 1, more: false, status: "running", cols: 100, rows: 30), to: view)
            XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString().prefix(1), "x")
            return view.displayRequests
        }
        // The Metal layer is drawn by SwiftTerm's own display pass.
        XCTAssertEqual(try displayRequestsForOutput(metal: true), 0)
        XCTAssertEqual(try displayRequestsForOutput(metal: false), 1)
    }
}
