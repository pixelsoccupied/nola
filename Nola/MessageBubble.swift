import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isStreaming: Bool
    var contentOverride: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }

            Text(renderedContent)
                .textSelection(.enabled)
                .padding(12)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .glassEffect(
                    message.role == .user
                        ? .regular.tint(.accentColor)
                        : .regular,
                    in: .rect(cornerRadius: 16)
                )
                .frame(maxWidth: 640, alignment: message.role == .user ? .trailing : .leading)
                .overlay(alignment: message.role == .user ? .bottomTrailing : .bottomLeading) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .offset(y: 18)
                        .opacity(isHovering ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
                }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .padding(.vertical, 4)
        .onHover { isHovering = $0 }
    }

    private var displayContent: String {
        let content = contentOverride ?? message.content
        if isStreaming && content.isEmpty {
            return "..."
        }
        return content
    }

    private var renderedContent: AttributedString {
        let raw = displayContent
        // Try markdown parsing; falls back to plain text on failure
        guard let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(raw)
        }
        return attributed
    }
}
