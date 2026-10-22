import AppKit
import MarkdownUI
import SwiftUI

/// Shared rendering for PR descriptions, conversation comments, and reviews.
struct GitHubMarkdown: View {
    let source: String
    let baseURL: URL?

    var body: some View {
        Markdown(source, baseURL: baseURL)
            .markdownTheme(.gitHubSidebar)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else {return .discarded}
                return .systemAction
            })
    }
}

private extension Theme {
    static let gitHubSidebar = Theme.gitHub
        .text {
            FontSize(12)
            ForegroundColor(.primary)
            BackgroundColor(nil)
        }
        .link {ForegroundColor(.accentColor)}
        .heading1 {configuration in
            configuration.label
                .markdownTextStyle {FontSize(18); FontWeight(.semibold)}
                .markdownMargin(top: 14, bottom: 8)
        }
        .heading2 {configuration in
            configuration.label
                .markdownTextStyle {FontSize(16); FontWeight(.semibold)}
                .markdownMargin(top: 12, bottom: 6)
        }
        .heading3 {configuration in
            configuration.label
                .markdownTextStyle {FontSize(14); FontWeight(.semibold)}
                .markdownMargin(top: 10, bottom: 6)
        }
        .paragraph {configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: 0, bottom: 8)
        }
        .blockquote {configuration in
            configuration.label
                .markdownTextStyle {ForegroundColor(.secondary)}
                .padding(.leading, 10)
                .overlay(alignment: .leading) {Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 3)}
                .markdownMargin(top: 0, bottom: 8)
        }
        .codeBlock {configuration in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(configuration.language ?? "コード")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration.content, forType: .string)
                    } label: {Image(systemName: "doc.on.doc")}
                        .buttonStyle(.borderless)
                        .help("コードをコピー")
                        .accessibilityLabel("コードをコピー")
                }.padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                ScrollView(.horizontal) {
                    configuration.label
                        .markdownTextStyle {FontFamilyVariant(.monospaced); FontSize(11)}
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(10)
                }
            }
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 0, bottom: 10)
        }
        .table {configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .markdownTableBorderStyle(.init(color: .secondary.opacity(0.25)))
                    .markdownTableBackgroundStyle(.alternatingRows(.clear, .primary.opacity(0.035)))
            }.markdownMargin(top: 0, bottom: 10)
        }
        .tableCell {configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {FontWeight(.semibold)}
                    BackgroundColor(nil)
                }
                .padding(.vertical, 6).padding(.horizontal, 8)
        }
}
