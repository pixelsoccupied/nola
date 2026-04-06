import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isStreaming: Bool
    var contentOverride: String?
    var isThinkingLive = false
    var thinkingContentOverride: String?
    var thinkingSecondsOverride: Double?
    var toolCallsOverride: [ChatViewModel.ToolCallRecord]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var showThinking = false
    @State private var showToolCalls = false

    private var thinkingText: String? {
        let text = thinkingContentOverride ?? message.thinkingContent
        // Hide empty thinking blocks (model outputs <think></think> when thinking disabled)
        if let t = text, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return text
    }

    private var thinkingSecs: Double? {
        thinkingSecondsOverride ?? message.thinkingSeconds
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 4) {
                // Thinking + Tool calls — side by side above the bubble
                if isThinkingLive || thinkingText != nil || !toolCallRecords.isEmpty {
                    HStack(spacing: 12) {
                        if isThinkingLive || thinkingText != nil {
                            thinkingSection
                        }
                        if !toolCallRecords.isEmpty {
                            toolCallSection
                        }
                    }
                }

                // Message content bubble — hidden when empty during thinking/tool use
                if isStreaming && displayContent.isEmpty {
                    // Typing indicator
                    TypingIndicator()
                        .padding(12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                } else if !displayContent.isEmpty {
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
                }
            }
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

    // MARK: - Thinking section

    @ViewBuilder
    private var thinkingSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .symbolEffect(.pulse, options: .repeating, isActive: isThinkingLive)
            if isThinkingLive, thinkingSecs == nil {
                Text("Thinking…")
            } else if let secs = thinkingSecs {
                Text("Thought for \(formatDuration(secs))")
            }
            Image(systemName: showThinking ? "chevron.down" : "chevron.right")
                .font(.caption2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 14)
        .contentShape(Rectangle())
        .onTapGesture { showThinking.toggle() }
        .popover(isPresented: $showThinking, arrowEdge: .bottom) {
            if let text = thinkingText, !text.isEmpty {
                ScrollView {
                    Text(renderMarkdown(text))
                        .textSelection(.enabled)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.numericText())
                        .animation(.easeIn(duration: 0.15), value: text)
                }
                .frame(width: 480, height: 300)
            }
        }
    }

    // MARK: - Tool calls

    private var toolCallRecords: [ChatViewModel.ToolCallRecord] {
        if let override = toolCallsOverride, !override.isEmpty {
            return override
        }
        guard let json = message.toolCallsJSON,
              let data = json.data(using: .utf8) else { return [] }
        struct Decoded: Codable {
            let name: String
            let arguments: String
            let result: String?
            let error: String?
        }
        guard let decoded = try? JSONDecoder().decode([Decoded].self, from: data) else { return [] }
        return decoded.map { item in
            let status: ChatViewModel.ToolCallRecord.Status
            if let err = item.error {
                status = .failed(err)
            } else if let res = item.result {
                status = .completed(res)
            } else {
                status = .running
            }
            return ChatViewModel.ToolCallRecord(
                name: item.name, arguments: item.arguments, status: status
            )
        }
    }

    @ViewBuilder
    private var toolCallSection: some View {
        let records = toolCallRecords
        let anyRunning = records.contains { if case .running = $0.status { return true }; return false }
        let anyFailed = records.contains { if case .failed = $0.status { return true }; return false }

        HStack(spacing: 6) {
            Image(systemName: "wrench.fill")
                .symbolEffect(.pulse, options: .repeating, isActive: anyRunning)
            if anyRunning {
                Text("Using tools…")
            } else {
                Text("\(records.count) tool call\(records.count == 1 ? "" : "s")")
            }
            if anyFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption2)
            }
            Image(systemName: showToolCalls ? "chevron.down" : "chevron.right")
                .font(.caption2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture { showToolCalls.toggle() }
        .popover(isPresented: $showToolCalls, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                        toolCallDetail(record)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 480, height: 300)
        }
    }

    private func toolCallDetail(_ record: ChatViewModel.ToolCallRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                switch record.status {
                case .running:
                    ProgressView().controlSize(.mini)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Text(record.name)
                    .font(.subheadline.weight(.medium))
            }

            if !record.arguments.isEmpty && record.arguments != "{}" {
                Text(record.arguments)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(5)
            }

            switch record.status {
            case .completed(let result):
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .failed(let error):
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            case .running:
                EmptyView()
            }

            Divider()
        }
    }

    // MARK: - Helpers

    private var displayContent: String {
        contentOverride ?? message.content
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m \(secs)s"
    }

    private var renderedContent: AttributedString {
        renderMarkdown(displayContent)
    }

    private func renderMarkdown(_ raw: String) -> AttributedString {
        guard let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(raw)
        }
        return attributed
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(.tertiary)
                    .frame(width: 6, height: 6)
                    .offset(y: animationOffset(for: i))
            }
        }
        .frame(height: 12)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func animationOffset(for index: Int) -> CGFloat {
        let delay = Double(index) * 0.15
        let progress = max(0, min(1, phase - delay))
        return -4 * sin(progress * .pi)
    }
}
