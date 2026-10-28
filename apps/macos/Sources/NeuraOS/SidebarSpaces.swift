import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SidebarSpace: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var selectedWorkspaceId: String?
}

/// Presentation groups are independent of Git workspaces and never move files.
struct SidebarSpaces: Codable {
    var spaces = [SidebarSpace(name: "メイン")]
    var activeId: String?
    var defaultSpaceId: String?
    var projectSpaces: [String: String] = [:]
    // Optional for compatibility with layouts saved before project reordering.
    var projectOrder: [String: [String]]?
    func projects(in spaceId: String, from projects: [Project]) -> [Project] {
        let members = projects.filter {owner(of: $0.id) == spaceId}
        let order = projectOrder?[spaceId] ?? []
        let ranks = Dictionary(order.enumerated().map {($0.element, $0.offset)}, uniquingKeysWith: {first, _ in first})
        return members.enumerated().sorted {
            let left = ranks[$0.element.id] ?? Int.max
            let right = ranks[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    /// Insert at the displayed boundary, including after the final project (nil).
    @discardableResult
    mutating func insertProject(_ id: String, before targetId: String?, in spaceId: String, projects: [Project]) -> Bool {
        guard spaces.contains(where: {$0.id == spaceId}), id != targetId else {return false}
        var ids = self.projects(in: spaceId, from: projects).map(\.id)
        guard let source = ids.firstIndex(of: id) else {return false}
        if let targetId, !ids.contains(targetId) {return false}
        let original = ids
        ids.remove(at: source)
        let destination = targetId.flatMap {ids.firstIndex(of: $0)} ?? ids.endIndex
        ids.insert(id, at: destination)
        guard ids != original else {return false}
        if projectOrder == nil {projectOrder = [:]}
        projectOrder?[spaceId] = ids
        return true
    }
    var active: SidebarSpace {spaces.first {$0.id == activeId} ?? spaces[0]}
    func owner(of projectId: String) -> String {projectSpaces[projectId] ?? defaultSpaceId ?? spaces[0].id}
    mutating func create(name: String) {
        let space = SidebarSpace(name: name)
        spaces.append(space)
        activeId = space.id
    }
    func adjacent(_ offset: Int) -> String? {
        guard let index = spaces.firstIndex(where: {$0.id == active.id}), spaces.indices.contains(index + offset) else {return nil}
        return spaces[index + offset].id
    }
    mutating func move(_ id: String, to targetId: String) {
        guard let source = spaces.firstIndex(where: {$0.id == id}),
              let target = spaces.firstIndex(where: {$0.id == targetId}), source != target else {return}
        // Older layouts implicitly assign ungrouped projects to the first space.
        defaultSpaceId = defaultSpaceId ?? spaces[0].id
        activeId = active.id
        let space = spaces.remove(at: source)
        spaces.insert(space, at: target)
    }
    mutating func rename(_ id: String, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = spaces.firstIndex(where: {$0.id == id}) else {return}
        spaces[index].name = name
    }
    mutating func remember(_ workspaceId: String?) {
        guard let index = spaces.firstIndex(where: {$0.id == active.id}) else {return}
        spaces[index].selectedWorkspaceId = workspaceId
    }
}

private extension UTType {
    static let sidebarSpace = UTType(exportedAs: "com.neuraos.sidebar-space")
}

struct SidebarSpaceDrag: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sidebarSpace)
    }
}

struct SidebarSpaceName: View {
    @Environment(AppModel.self) private var model
    let space: SidebarSpace
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Workspace名", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {finish()}
                    .onExitCommand {editing = false; focused = false}
                    .onChange(of: focused) {_, value in if !value {finish()}}
                    .onDisappear {finish()}
            } else {
                Button {
                    draft = space.name
                    editing = true
                    focused = true
                } label: {
                    Text(space.name).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("クリックしてWorkspace名を編集")
                .accessibilityLabel("Workspace名を編集: \(space.name)")
            }
        }.font(.system(size: 13, weight: .semibold)).lineLimit(1)
    }

    private func finish() {
        guard editing else {return}
        model.sidebarSpaces.rename(space.id, name: draft)
        editing = false
        focused = false
    }
}

/// Keep terminal observation in each button, away from sidebar menus and gestures.
struct SidebarSpaceButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    let space: SidebarSpace
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let activity = model.sidebarSpaces.activity(in: space.id, workspaces: model.state.workspaces,
                                                   terminals: model.state.terminals, connected: model.connected)
        let description = activity.map {"\(space.name)・\($0.label)"} ?? space.name
        Button(action: action) {
            Group {
                if activity == .working {
                    if reduceMotion {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    } else {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    }
                } else {
                    Circle().fill(activity == .waiting ? Color.orange :
                                  isSelected ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover {hovered = $0}
        .help(description)
        .accessibilityLabel(space.name)
        .accessibilityValue(activity?.label ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension SidebarSpaces {
    func activity(in spaceId: String, workspaces: [Workspace], terminals: [TerminalRecord], connected: Bool) -> AgentActivity? {
        let workspaceIds = Set(workspaces.filter {owner(of: $0.projectId) == spaceId}.map(\.id))
        return WorkspaceActivity(terminals: terminals.filter {workspaceIds.contains($0.workspaceId)}, connected: connected).activity
    }
}

/// Own a precise, phased gesture only after it locks horizontally inside the sidebar.
struct SidebarSwipeArea: NSViewRepresentable {
    var canBegin: () -> Bool
    var onProgress: (CGFloat) -> Void
    var onEnd: (Int?) -> Void
    func makeNSView(context: Context) -> SwipeView {SwipeView()}
    func updateNSView(_ view: SwipeView, context: Context) {
        view.canBegin = canBegin
        view.onProgress = onProgress
        view.onEnd = onEnd
    }
    final class SwipeView: NSView {
        var canBegin: (() -> Bool)?
        var onProgress: ((CGFloat) -> Void)?
        var onEnd: ((Int?) -> Void)?
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var gesture = SidebarSwipeGesture()
        private var tracking = false
        private var consumeMomentum = false
        override func hitTest(_ point: NSPoint) -> NSView? {nil}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {NSEvent.removeMonitor(monitor); self.monitor = nil}
            if let resignObserver {NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil}
            if tracking {onEnd?(nil)}
            tracking = false
            consumeMomentum = false
            guard let window else {return}
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                guard let self else {return}
                if self.tracking, self.gesture.isHorizontal {self.onEnd?(nil)}
                self.tracking = false
                self.consumeMomentum = false
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, event.hasPreciseScrollingDeltas else {return event}
                if !event.momentumPhase.isEmpty {return self.consumeMomentum ? nil : event}
                if event.phase.contains(.began) {
                    if self.tracking, self.gesture.isHorizontal {self.onEnd?(nil)}
                    self.tracking = false
                    self.consumeMomentum = false
                    guard self.canBegin?() != false,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {return event}
                    self.gesture = SidebarSwipeGesture()
                    self.tracking = true
                    self.consumeMomentum = false
                }
                guard self.tracking else {return event}
                self.gesture.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                    timestamp: event.timestamp,
                                    isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice)
                let consumed = self.gesture.isHorizontal
                if consumed {self.onProgress?(self.gesture.translation)}
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    self.tracking = false
                    self.consumeMomentum = consumed
                    if consumed {
                        self.onEnd?(event.phase.contains(.cancelled) ? nil : self.gesture.destination(width: self.bounds.width, timestamp: event.timestamp))
                    }
                }
                return consumed ? nil : event
            }
        }
        deinit {
            if let monitor {NSEvent.removeMonitor(monitor)}
            if let resignObserver {NotificationCenter.default.removeObserver(resignObserver)}
        }
    }
}

struct SidebarSwipeGesture {
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var vertical = false
    private var lastTimestamp: TimeInterval?
    private var lastMovementTimestamp: TimeInterval?
    private var velocity: CGFloat = 0
    private(set) var isHorizontal = false
    // Device-positive motion navigates forward; the page follows the fingers to the left.
    var translation: CGFloat {isHorizontal ? -x : 0}
    mutating func update(x dx: CGFloat, y dy: CGFloat, timestamp: TimeInterval,
                         isDirectionInvertedFromDevice: Bool = false) {
        guard !vertical else {return}
        let direction: CGFloat = isDirectionInvertedFromDevice ? -1 : 1
        let delta = dx * direction
        x += delta; y += dy * direction
        if !isHorizontal {
            if abs(y) > 8, abs(y) > abs(x) {vertical = true; return}
            if abs(x) > 8, abs(x) > abs(y) * 1.4 {isHorizontal = true}
        }
        if abs(delta) > 0.01 {
            if let previous = lastTimestamp, timestamp > previous {
                let instantaneous = -delta / CGFloat(max(timestamp - previous, 1.0 / 120))
                velocity = velocity * 0.35 + instantaneous * 0.65
            }
            lastMovementTimestamp = timestamp
        }
        lastTimestamp = timestamp
    }
    func destination(width: CGFloat, timestamp: TimeInterval) -> Int? {
        guard isHorizontal, width > 0 else {return nil}
        // A deliberate drag or a short flick commits on release. Pausing removes flick intent.
        let recentVelocity = timestamp - (lastMovementTimestamp ?? timestamp) < 0.1 ? velocity : 0
        let threshold = min(90, width * 0.28)
        let projected = translation + max(-width, min(width, recentVelocity)) * 0.16
        guard abs(translation) >= 18, abs(projected) >= threshold,
              projected * translation > 0 else {return nil}
        return translation < 0 ? 1 : -1
    }
    static func resistedTranslation(_ translation: CGFloat, width: CGFloat, canNavigate: Bool) -> CGFloat {
        guard width > 0 else {return 0}
        if !canNavigate {return translation * 0.22 / (1 + abs(translation) / width)}
        return max(-width, min(width, translation))
    }
}

struct NewSidebarSpaceSheet: View {
    @Environment(AppModel.self) private var model
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

/// Private drag payload keeps project ordering separate from file and text drops.
struct SidebarProjectDrag: Codable {
    static let typeIdentifier = "com.neuraos.sidebar-project"
    let projectId: String
    let spaceId: String

    var provider: NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .ownProcess) {completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// Ordinary list rows accept drops; section headers are reserved by macOS for disclosure.
struct SidebarProjectDropTarget: ViewModifier {
    let perform: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isTargeted {
                    Capsule().fill(Color.accentColor).frame(height: 2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [SidebarProjectDrag.typeIdentifier], isTargeted: $isTargeted, perform: perform)
    }
}
