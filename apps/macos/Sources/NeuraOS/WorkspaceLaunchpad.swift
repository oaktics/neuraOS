import SwiftUI

struct WorkspaceLaunchpad: View {
    let name: String
    let launch: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {heading; Spacer(); conversationButton}
                VStack(alignment: .leading, spacing: 12) {heading; conversationButton}
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {launchCards.frame(minWidth: 150)}
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {launchCards}
            }
        }
        .padding(24)
        .frame(maxWidth: 1040)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
    }

    @ViewBuilder private var launchCards: some View {
        launchCard("Codex", icon: "sparkle", color: .blue, kind: "codex")
        launchCard("Claude Code", icon: "asterisk", color: .orange, kind: "claude")
        launchCard("Terminal", icon: "terminal", color: .purple, kind: "shell")
        launchCard("Browser", icon: "globe", color: .teal, kind: "browser")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ホーム").font(.caption).foregroundStyle(.secondary)
            Text(name).font(.system(size: 22, weight: .semibold)).lineLimit(1)
        }
    }

    private var conversationButton: some View {
        Button {launch("conversation")} label: {
            Label("新しい会話", systemImage: "plus.bubble").padding(.horizontal, 4)
        }.buttonStyle(.borderedProminent).controlSize(.large)
    }

    private func launchCard(_ title: String, icon: String, color: Color, kind: String) -> some View {
        Button {launch(kind)} label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(color).frame(width: 32, height: 32)
                    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(WorkspaceLaunchCardStyle())
        .accessibilityLabel(title)
    }
}

private struct WorkspaceLaunchCardStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        WorkspaceLaunchCardBody(content: configuration.label, pressed: configuration.isPressed)
            .opacity(enabled ? 1 : 0.5)
    }
}

private struct WorkspaceLaunchCardBody<Content: View>: View {
    let content: Content
    let pressed: Bool
    @State private var hovered = false
    var body: some View {
        content
            .background(hovered || pressed ? Color.accentColor.opacity(pressed ? 0.13 : 0.06) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {RoundedRectangle(cornerRadius: 12).strokeBorder(hovered ? Color.accentColor.opacity(0.4) : Palette.line)}
            .onHover {hovered = $0}
    }
}
