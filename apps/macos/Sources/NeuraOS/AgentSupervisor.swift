import SwiftUI

struct ManagedAgent: Decodable, Identifiable {
    let id: String
    let terminalId: String
    let workspaceId: String
    let name: String
    let status: String
    var provider: String? = nil
    var parentTaskId: String? = nil
    var channelState: String? = nil
    var watching: [Watch]? = nil
    struct Watch: Decodable {let taskId: String}
    let updatedAt: String
    let turnId: String?
    let lastTurnStatus: String?
    let summary: String?
    let pending: [Pending]
    let requests: [AgentQuestionRequest]
    struct Pending: Decodable {let id: String; let text: String}
    func isVisible(runningTerminalIDs: Set<String>, includeStopped: Bool) -> Bool {
        includeStopped || runningTerminalIDs.contains(terminalId)
    }
    var statusLabel: String {
        switch status {case "working": return "作業中"; case "waiting": return "回答待ち"; case "idle": return "次の指示待ち"; case "failed": return "失敗"; default: return "中断"}
    }
}
struct AgentQuestionRequest: Decodable, Identifiable {
    let id: RequestID
    let method: String
    let params: Params
    enum RequestID: Decodable, Hashable {
        case number(Int), string(String)
        init(from decoder: Decoder) throws {let value = try decoder.singleValueContainer(); if let number = try? value.decode(Int.self) {self = .number(number)} else {self = .string(try value.decode(String.self))}}
        var value: Any {switch self {case .number(let n): return n; case .string(let s): return s}}
    }
    struct Params: Decodable {let questions: [Question]?}
    struct Question: Decodable, Identifiable {
        let id: String; let question: String; let isSecret: Bool?; let options: [Option]?
        struct Option: Decodable {let label: String; let description: String?}
    }
}

struct ManagedAgents: Decodable {let agents: [ManagedAgent]; let revision: Int}
struct AgentConversation: Decodable {
    let agent: ManagedAgent
    let history: History
    struct History: Decodable {let data: [Turn]; let nextCursor: String?}
    struct Turn: Decodable, Identifiable {let id: String; let status: String; let items: [Item]}
    struct Item: Decodable, Identifiable {
        let id: String; let type: String; let text: String?; let command: String?; let aggregatedOutput: String?; let content: [Input]?
        struct Input: Decodable {let type: String; let text: String?}
        var display: String {text ?? command.map { $0 + (aggregatedOutput.map {"\n" + $0} ?? "") } ?? content?.compactMap(\.text).joined(separator: "\n") ?? ""}
        var label: String {type == "userMessage" ? "指示" : type == "agentMessage" ? "応答" : type == "commandExecution" ? "コマンド" : type}
    }
}

struct AgentHistoryWindow {
    private(set) var turns: [AgentConversation.Turn] = []
    private(set) var nextCursor: String?
    mutating func refresh(_ page: AgentConversation.History) {
        let incoming = Array(page.data.reversed())
        let incomingIDs = Set(incoming.map(\.id))
        // Preserve the contiguous older prefix, including turns that just fell off
        // the newest page. With no overlap (e.g. a long disconnection), reset the
        // window and cursor together so history can be fetched without a hidden gap.
        if let shared = incoming.first(where: {item in turns.contains {$0.id == item.id}}),
           let index = turns.firstIndex(where: {$0.id == shared.id}), index > 0 {
            turns = turns[..<index].filter {!incomingIDs.contains($0.id)} + incoming
        } else {
            turns = incoming; nextCursor = page.nextCursor
        }
    }
    mutating func prepend(_ page: AgentConversation.History, expectedCursor: String) {
        // A refresh may have reset pagination while this request was in flight.
        guard nextCursor == expectedCursor else {return}
        let existing = Set(turns.map(\.id))
        turns = page.data.reversed().filter {!existing.contains($0.id)} + turns
        nextCursor = page.nextCursor
    }
}

struct AgentSupervisor: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    let visible: Bool
    @State private var agents: [ManagedAgent] = []
    @State private var selected: String?
    @State private var lastReadStamp: String?
    @State private var history = AgentHistoryWindow()
    @State private var text = ""
    @State private var answers: [String: String] = [:]
    @State private var steer = false
    @State private var busy = false
    @State private var error: String?
    @State private var includeStopped = false
    private var visibleAgents: [ManagedAgent] {
        let running = Set(model.state.terminals.filter {$0.status == "running"}.map(\.id))
        return agents.filter {$0.isVisible(runningTerminalIDs: running, includeStopped: includeStopped)}
    }
    private var current: ManagedAgent? {visibleAgents.first {$0.id == selected}}
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("エージェントの作業一覧").font(.headline).padding()
                Toggle("停止した作業も表示", isOn: $includeStopped)
                    .toggleStyle(.checkbox).font(.callout).padding(.horizontal).padding(.bottom, 8)
                List(visibleAgents, selection: $selected) {agent in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(agent.name).lineLimit(1)
                        Text("\(agent.provider == "claude" ? "Claude" : "Codex") · \((agent.watching?.isEmpty == false) ? "監督" : agent.parentTaskId != nil ? "委任先" : "独立")").font(.caption2).foregroundStyle(.secondary)
                        HStack {Text(workspaceName(agent)); Spacer(); Text(agent.statusLabel)}.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(agent.id)
                }
                if visibleAgents.isEmpty {Text(includeStopped ? "このプロジェクトの作業はありません。" : "起動中のエージェントはありません。停止した作業は「停止した作業も表示」から確認・再開できます。").font(.callout).foregroundStyle(.secondary).padding()}
            }.frame(minWidth: 200, idealWidth: 250, maxWidth: 340)
            VStack(alignment: .leading, spacing: 12) {
                if let agent = current {
                    HStack {
                        VStack(alignment: .leading) {Text(agent.name).font(.headline); Text(agent.statusLabel).foregroundStyle(.secondary)}
                        Spacer()
                        Button("作業を開く") {model.select(agent.workspaceId); model.requestedTerminalId = agent.terminalId}
                        if let turn = agent.turnId {Button("中断", role: .destructive) {run(["type": "agent.interrupt", "agentId": agent.id, "expectedTurnId": turn])}.disabled(busy)}
                        if model.terminal(id: agent.terminalId)?.status != "running" {Button("再開") {run(["type": "terminal.open", "workspaceId": agent.workspaceId, "provider": agent.provider ?? "codex", "resumeId": agent.id])}.disabled(busy)}
                    }
                    if !agent.pending.isEmpty {Text("送信待ちの指示: \(agent.pending.count)件").font(.caption).foregroundStyle(.secondary)}
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if history.nextCursor != nil {Button("以前の会話を読み込む") {Task {await loadOlder()}}}
                            ForEach(history.turns) {turn in
                                ForEach(turn.items.filter {!$0.display.isEmpty}) {item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.label).font(.caption).foregroundStyle(.secondary)
                                        Text(item.display).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(agent.requests) {request in
                        if let questions = request.params.questions {
                            ForEach(questions) {question in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(question.question).font(.callout)
                                    if let options = question.options {
                                        HStack {ForEach(options, id: \.label) {option in Button(option.label) {answers[question.id] = option.label}.help(option.description ?? "")}}
                                    }
                                    if question.isSecret == true {SecureField("回答", text: answerBinding(question.id))}
                                    else {TextField("回答", text: answerBinding(question.id)).textFieldStyle(.roundedBorder)}
                                }
                            }
                            Button("回答を送信") {
                                let result = Dictionary(uniqueKeysWithValues: questions.map {($0.id, ["answers": [answers[$0.id] ?? ""]])})
                                run(["type": "agent.respond", "agentId": agent.id, "requestId": request.id.value, "result": ["answers": result]])
                            }.disabled(busy || questions.contains {(answers[$0.id] ?? "").isEmpty})
                        } else {Text("エージェントが操作の確認を待っています。「作業を開く」から確認してください。").font(.callout)}
                    }
                    Divider()
                    if agent.provider == "claude" {Text(agent.channelState == "connected" ? "Channels受信確認済み。指示は現在の応答後に届きます。" : "Channels受信未確認。指示は保持されています。ターミナルの標準確認、Claudeの対応バージョン・アカウント・組織設定を確認してください。").font(.caption).foregroundStyle(.secondary)}
                    TextField("このエージェントへの指示", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                    HStack {
                        Toggle("実行中の作業へすぐ反映", isOn: $steer).disabled(agent.turnId == nil || agent.provider == "claude")
                        Spacer()
                        Button(steer && agent.turnId != nil && agent.provider != "claude" ? "方向修正を送信" : "指示を送信") {send(agent)}
                            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.terminal(id: agent.terminalId)?.status != "running")
                    }
                    Text("応答の終了は、依頼やテストの完了を保証するものではありません。").font(.caption).foregroundStyle(.secondary)
                } else {ContentUnavailableView("エージェントを選択", systemImage: "person.3", description: Text("会話を確認し、追加の指示を送れます。"))}
                if let error {Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)}
            }.padding().frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: visible) {guard visible else {return}; while !Task.isCancelled {await refresh(); do {try await Task.sleep(for: .seconds(3))} catch {return}}}
        .onChange(of: visibleAgents.map(\.id)) {_, _ in reconcileSelection()}
        .task(id: selected) {history = AgentHistoryWindow(); lastReadStamp = nil; steer = false; text = ""; answers = [:]; await read()}
    }
    private func reconcileSelection() {
        if !visibleAgents.contains(where: {$0.id == selected}) {selected = visibleAgents.first?.id}
    }
    private func answerBinding(_ id: String) -> Binding<String> {Binding(get: {answers[id] ?? ""}, set: {answers[id] = $0})}
    private func workspaceName(_ agent: ManagedAgent) -> String {model.state.workspaces.first {$0.id == agent.workspaceId}?.name ?? "作業"}
    private func refresh() async {
        do {
            let result: ManagedAgents = try await model.api.get("v1/agents")
            let ids = Set(model.state.workspaces.filter {$0.projectId == workspace.projectId}.map(\.id))
            agents = result.agents.filter {ids.contains($0.workspaceId)}
            reconcileSelection()
            await read()
        } catch {self.error = error.localizedDescription}
    }
    private func read() async {
        guard let id = selected else {return}
        let stamp = id + (current?.updatedAt ?? "")
        // Command output can change without an agent message or registry timestamp.
        guard lastReadStamp != stamp || ["working", "waiting"].contains(current?.status ?? "") else {return}
        do {let value: AgentConversation = try await model.api.get("v1/agents/\(id)"); guard selected == id else {return}; history.refresh(value.history); lastReadStamp = stamp; error = nil}
        catch {self.error = error.localizedDescription}
    }
    private func loadOlder() async {
        guard let id = selected, let cursor = history.nextCursor else {return}
        do {let page: AgentConversation = try await model.api.get("v1/agents/\(id)", query: ["cursor": cursor]); guard selected == id else {return}; history.prepend(page.history, expectedCursor: cursor)}
        catch {self.error = error.localizedDescription}
    }
    private func send(_ agent: ManagedAgent) {
        var command: [String: Any] = ["type": "agent.send", "agentId": agent.id, "text": text, "mode": steer && agent.turnId != nil && agent.provider != "claude" ? "steer" : "queue"]
        if steer, agent.provider != "claude", let turn = agent.turnId {command["expectedTurnId"] = turn}
        run(command, clearText: true)
    }
    private func run(_ command: [String: Any], clearText: Bool = false) {
        busy = true
        Task {
            defer {busy = false}
            do {let _: IgnoredResponse = try await model.api.command(command); if clearText {text = ""}; await refresh()}
            catch {self.error = error.localizedDescription}
        }
    }
    private struct IgnoredResponse: Decodable {}
}
