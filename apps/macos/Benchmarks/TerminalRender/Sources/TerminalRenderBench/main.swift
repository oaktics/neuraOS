import AppKit
import MetalKit
import SwiftTerm

// Deterministic terminal render workload driven through SwiftTerm's public
// AppKit API. It reports CPU time, which is less sensitive to other load on
// the machine than wall-clock time; it is still not noise-free (core type and
// frequency vary), so compare repeated, alternating runs.
//
//   swift run -c release --package-path apps/macos/Benchmarks/TerminalRender TerminalRenderBench --frames 200
//   SWIFTTERM_PATH=/path/to/SwiftTerm-v1.20.0 swift run -c release --scratch-path /tmp/bench-upstream ...

func threadCPU() -> Double {
    var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
    return Double(t.tv_sec) * 1e3 + Double(t.tv_nsec) / 1e6
}
func processCPU() -> Double {
    var t = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
    return Double(t.tv_sec) * 1e3 + Double(t.tv_nsec) / 1e6
}
func wall() -> Double {
    var t = timespec(); clock_gettime(CLOCK_MONOTONIC_RAW, &t)
    return Double(t.tv_sec) * 1e3 + Double(t.tv_nsec) / 1e6
}

struct Workload {
    let name: String
    let setup: String
    let frames: [String]
}

let esc = "\u{1b}"
func at(_ row: Int, _ col: Int = 1) -> String {"\(esc)[\(row);\(col)H"}

/// Mixed-width body text similar to an agent transcript.
func bodyLine(_ index: Int, cols: Int) -> String {
    let samples = [
        "\(esc)[1m⏺\(esc)[0m Reading \(esc)[36mapps/macos/Sources/NeuraOS/NativeTerminal.swift\(esc)[0m (352 lines)",
        "  \(esc)[2m⎿\(esc)[0m  描画パスを確認しています — グリフキャッシュのキーは \(esc)[33mPostScript名\(esc)[0m でした",
        "\(esc)[32m+\(esc)[0m     let entry = glyphCache[key] ?? rasterize(font, glyph)  \(esc)[2m// cached\(esc)[0m",
        "\(esc)[31m-\(esc)[0m     let name = CTFontCopyPostScriptName(font) as String",
        "│ \(esc)[1mMetric\(esc)[0m        │ before │ after │ 備考 🚀 │",
        "├───────────────┼────────┼───────┼─────────┤",
        "  ✅ tests passed · ⚠️ 2 warnings · 한국어 텍스트 · Ελληνικά · عربى",
        "\(esc)[48;5;236m\(esc)[38;5;252m  func draw(in view: MTKView) { buildDrawData(scale: scale) }      \(esc)[0m",
        "  1. Upgrade the renderer  2. Measure again  3. 本番へリリース 🎉",
        "\(esc)[38;2;215;119;87m●\(esc)[0m Bash(swift test --package-path apps/macos) \(esc)[2m(ctrl+o to expand)\(esc)[0m",
    ]
    let text = samples[index % samples.count]
    return "\(text) \(esc)[2m#\(index)\(esc)[0m"
}

func makeWorkloads(cols: Int, rows: Int, frames: Int) -> [Workload] {
    var setup = "\(esc)[2J\(esc)[H"
    for row in 1...(rows - 8) {setup += at(row) + bodyLine(row, cols: cols)}
    let box = String(repeating: "─", count: cols - 2)
    setup += at(rows - 4) + "╭\(box)╮" + at(rows - 3) + "│ > 続きを実装して" + at(rows - 3, cols) + "│" + at(rows - 2) + "╰\(box)╯"
    setup += at(rows) + "  \(esc)[2m? for shortcuts · ⏵⏵ bypass permissions on\(esc)[0m"
    let spinner = ["✻", "✽", "✶", "✳", "✢", "·"]
    func spinnerLine(_ frame: Int) -> String {
        "\(esc)[38;2;215;119;87m\(spinner[frame % spinner.count])\(esc)[0m Thinking… \(esc)[2m(\(frame / 10)s · ↓ \(1200 + frame * 7) tokens · esc to interrupt)\(esc)[0m\(esc)[K"
    }
    func status(_ frame: Int) -> String {
        "  \(esc)[2m? for shortcuts · ⏵⏵ bypass permissions on · \(frame % 100)% context\(esc)[0m\(esc)[K"
    }
    // 1. Differential update: only the spinner row and the status row are written.
    let diff = (0..<frames).map {at(rows - 6) + spinnerLine($0) + at(rows) + status($0)}
    // 2. Region repaint: the dynamic region is erased and rewritten each frame,
    //    most rows with unchanged content (Ink-style full repaint of the live area).
    let region = (0..<frames).map { frame -> String in
        var out = "\(esc)[?2026h" + at(rows - 24) + "\(esc)[J"
        for row in (rows - 24)...(rows - 8) {out += at(row) + bodyLine(row, cols: cols)}
        out += at(rows - 6) + spinnerLine(frame)
        out += at(rows - 4) + "╭\(box)╮" + at(rows - 3) + "│ > 続きを実装して" + at(rows - 3, cols) + "│" + at(rows - 2) + "╰\(box)╯"
        out += at(rows) + status(frame) + "\(esc)[?2026l"
        return out
    }
    // 3. Streaming: two new transcript lines scroll the screen each frame.
    let stream = (0..<frames).map { frame -> String in
        at(rows) + "\r\n" + bodyLine(1000 + frame * 2, cols: cols) + "\r\n" + bodyLine(1001 + frame * 2, cols: cols)
    }
    // 4. Full repaint with new content on every row.
    let full = (0..<frames).map { frame -> String in
        var out = "\(esc)[H"
        for row in 1...rows {out += at(row) + bodyLine(row + frame, cols: cols) + "\(esc)[K"}
        return out
    }
    return [Workload(name: "spinner-diff", setup: setup, frames: diff),
            Workload(name: "region-repaint", setup: setup, frames: region),
            Workload(name: "stream-scroll", setup: setup, frames: stream),
            Workload(name: "full-repaint", setup: setup, frames: full)]
}

func spin(_ seconds: Double) {RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))}

func option(_ name: String, _ fallback: Int) -> Int {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--\(name)"), index + 1 < args.count, let value = Int(args[index + 1]) else {return fallback}
    return value
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let frameCount = option("frames", 240)
let visible = CommandLine.arguments.contains("--visible")
let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
window.contentView = view
if visible {window.orderFrontRegardless()}
do {try view.setUseMetal(true)} catch {print("metal unavailable: \(error)"); exit(2)}
spin(0.2)
let terminal = view.getTerminal()
let cols = terminal.cols, rows = terminal.rows
let metal = view.subviews.compactMap {$0 as? MTKView}.first
let scale = window.backingScaleFactor
print("config cols=\(cols) rows=\(rows) scale=\(scale) frames=\(frameCount) mtkView=\(metal != nil) visible=\(visible)")


/// Times SwiftTerm's own MTKView delegate without touching its internals.
final class DrawProbe: NSObject, MTKViewDelegate {
    let target: MTKViewDelegate
    var cpu = 0.0, count = 0
    init(_ target: MTKViewDelegate) {self.target = target}
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {target.mtkView(view, drawableSizeWillChange: size)}
    func draw(in view: MTKView) {
        let start = threadCPU()
        target.draw(in: view)
        cpu += threadCPU() - start
        count += 1
    }
}
var probe: DrawProbe?
if let metal, let delegate = metal.delegate {
    probe = DrawProbe(delegate)
    metal.delegate = probe
}
let only = CommandLine.arguments.firstIndex(of: "--only").map {CommandLine.arguments[$0 + 1]}
for workload in makeWorkloads(cols: cols, rows: rows, frames: frameCount) where only == nil || only == workload.name {
    view.feed(text: "\(esc)c")
    view.feed(text: workload.setup)
    spin(0.3)
    probe?.cpu = 0; probe?.count = 0
#if NEURA_RENDER_STATISTICS
    let statisticsStart = view.metalRenderStatistics ?? MetalRenderStatistics()
#endif
    var feedCPU = 0.0
    let processStart = processCPU(), mainStart = threadCPU(), wallStart = wall()
    for frame in workload.frames {
        let t = threadCPU()
        let drawsBefore = probe?.count ?? 0
        view.feed(text: frame)
        feedCPU += threadCPU() - t
        // SwiftTerm publishes the dirty rows to its renderer from a ~60 Hz
        // main-queue timer. Wait for that pass, then make sure exactly one
        // draw sees this frame's rows: AppKit throttles automatic draws for
        // windows that are not on screen, which would make the work per
        // run depend on machine load.
        var waited = 0
        while terminal.getUpdateRange() != nil && waited < 400 {spin(0.001); waited += 1}
        if let metal, (probe?.count ?? 0) == drawsBefore {metal.draw()}
        // Let the GPU completion handler release SwiftTerm's frame gate.
        spin(0.003)
    }
    spin(0.1)
    let processTotal = processCPU() - processStart, mainTotal = threadCPU() - mainStart, wallTotal = wall() - wallStart
    let n = Double(workload.frames.count)
    print(String(format: "result workload=%@ frames=%d draws=%d draw_cpu_ms_per_frame=%.3f feed_cpu_ms_per_frame=%.3f main_cpu_ms_per_frame=%.3f process_cpu_ms_per_frame=%.3f wall_s=%.2f",
                 workload.name, workload.frames.count, probe?.count ?? -1, (probe?.cpu ?? 0) / n, feedCPU / n, mainTotal / n, processTotal / n, wallTotal / 1000))
#if NEURA_RENDER_STATISTICS
    if let end = view.metalRenderStatistics {
        print(String(format: "work   workload=%@ rows_rebuilt_per_frame=%.2f rows_repositioned_per_frame=%.2f rows_reused_per_draw=%.2f glyphs_rasterized=%d runs_shaped=%d",
                     workload.name, Double(end.rowsRebuilt - statisticsStart.rowsRebuilt) / n,
                     Double(end.rowsRepositioned - statisticsStart.rowsRepositioned) / n,
                     Double(end.rowsReused - statisticsStart.rowsReused) / Double(max(1, end.frames - statisticsStart.frames)),
                     end.glyphsRasterized - statisticsStart.glyphsRasterized, end.runsShaped - statisticsStart.runsShaped))
    }
#endif
}
