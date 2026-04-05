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
                    HStack(spacing: 6) {
                        Text(message.timestamp, style: .time)
                        if message.role == .assistant, !isStreaming {
                            if let seconds = message.generationSeconds {
                                Text("·")
                                Text(formatDuration(seconds))
                            }
                            if let tps = message.tokensPerSecond {
                                Text("·")
                                Text(String(format: "%.0f tok/s", tps))
                            }
                            if let mem = message.memoryBytesUsed {
                                Text("·")
                                Text(String(format: "%.1f GB", Double(mem) / 1_073_741_824))
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .offset(y: 18)
                    .opacity(isHovering ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
                }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .padding(.vertical, 6)
        .onHover { isHovering = $0 }
    }

    private var displayContent: String {
        let content = contentOverride ?? message.content
        if isStreaming && content.isEmpty {
            return "..."
        }
        return content
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m \(secs)s"
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
