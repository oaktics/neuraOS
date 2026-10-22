import SwiftUI
import AppKit

struct SidebarSpace: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var selectedWorkspaceId: String?
}

/// Presentation groups are independent of Git workspaces and never move files.
struct SidebarSpaces: Codable {
    var spaces = [SidebarSpace(name: "メイン")]
    var activeId: String?
    var projectSpaces: [String: String] = [:]
    var active: SidebarSpace {spaces.first {$0.id == activeId} ?? spaces[0]}
    func owner(of projectId: String) -> String {projectSpaces[projectId] ?? spaces[0].id}
    mutating func create(name: String) {
        let space = SidebarSpace(name: name)
        spaces.append(space)
        activeId = space.id
    }
    func adjacent(_ offset: Int) -> String? {
        guard let index = spaces.firstIndex(where: {$0.id == active.id}), spaces.indices.contains(index + offset) else {return nil}
        return spaces[index + offset].id
    }
    mutating func remember(_ workspaceId: String?) {
        guard let index = spaces.firstIndex(where: {$0.id == active.id}) else {return}
        spaces[index].selectedWorkspaceId = workspaceId
    }
}

/// Observe only this sidebar's wheel events; vertical scrolling and other panes stay native.
struct SidebarSwipeArea: NSViewRepresentable {
    var onSwipe: (Int) -> Void
    func makeNSView(context: Context) -> SwipeView {SwipeView()}
    func updateNSView(_ view: SwipeView, context: Context) {view.onSwipe = onSwipe}
    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var gesture = SidebarSwipeGesture()
        override func hitTest(_ point: NSPoint) -> NSView? {nil}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {NSEvent.removeMonitor(monitor); self.monitor = nil}
            guard window != nil else {return}
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      event.hasPreciseScrollingDeltas else {return event}
                if event.phase.contains(.began) {self.gesture = SidebarSwipeGesture()}
                guard event.momentumPhase.isEmpty else {return event}
                let direction = self.gesture.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
                if let direction {self.onSwipe?(direction)}
                let consumed = self.gesture.isHorizontal
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {self.gesture = SidebarSwipeGesture()}
                return consumed ? nil : event
            }
        }
        deinit {if let monitor {NSEvent.removeMonitor(monitor)}}
    }
}

struct SidebarSwipeGesture {
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var fired = false
    private var vertical = false
    private(set) var isHorizontal = false
    mutating func update(x dx: CGFloat, y dy: CGFloat) -> Int? {
        guard !fired, !vertical else {return nil}
        x += dx; y += dy
        if !isHorizontal, abs(y) > 12, abs(y) > abs(x) {vertical = true; return nil}
        if abs(x) > 12, abs(x) > abs(y) * 1.5 {isHorizontal = true}
        guard isHorizontal, abs(x) >= 65 else {return nil}
        fired = true
        return x < 0 ? 1 : -1
    }
}

struct NewSidebarSpaceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新しいWorkspace").font(.title2.bold())
            Text("プロジェクトを用途ごとにまとめて、サイドバーの左右スワイプで切り替えられます。")
                .foregroundStyle(.secondary)
            TextField("名前（例：仕事、個人）", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("キャンセル") {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                Button("作成") {model.createSpace(name: name); dismiss()}
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 380)
    }
}
