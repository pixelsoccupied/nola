import SwiftData
import SwiftUI

struct ChatView: View {
    @Environment(MLXService.self) private var mlxService
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.modelContext) private var modelContext

    let conversation: Conversation
    var chatViewModel: ChatViewModel

    @State private var draft = ""
    @FocusState private var isInputFocused: Bool

    private var sortedMessages: [Message] { conversation.sortedMessages }

    var body: some View {
        Group {
            if conversation.messages.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        let messages = sortedMessages
                        let streamingId = chatViewModel.isGenerating ? messages.last(where: { $0.role == .assistant })?.id : nil
                        VStack(spacing: 0) {
                            ForEach(messages) { message in
                                if message.id == streamingId {
                                    StreamingMessageBubble(
                                        message: message,
                                        chatViewModel: chatViewModel
                                    )
                                } else {
                                    MessageBubble(message: message, isStreaming: false)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [Color(.windowBackgroundColor), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 40)
                        .allowsHitTesting(false)
                    }
                    .overlay {
                        StreamingScrollTrigger(
                            chatViewModel: chatViewModel,
                            lastMessageId: sortedMessages.last?.id,
                            proxy: proxy
                        )
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                errorBanner
                inputBar
            }
        }
        .background {
            LinearGradient(
                colors: [
                    Color(.windowBackgroundColor),
                    Color(red: 0.08, green: 0.12, blue: 0.18).opacity(0.8),
                    Color(red: 0.14, green: 0.08, blue: 0.06).opacity(0.5)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .onAppear { isInputFocused = true }
        .onChange(of: conversation.id) { isInputFocused = true }
        .onChange(of: chatViewModel.isGenerating) {
            if !chatViewModel.isGenerating { isInputFocused = true }
        }
    }

    // MARK: - Error banner

    @ViewBuilder
    private var errorBanner: some View {
        if let error = chatViewModel.generationError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.message)
                        .font(.subheadline)
                }
                Spacer()
                if error.isModelIncompatible {
                    Button("Try Another") {
                        chatViewModel.dismissError()
                        NotificationCenter.default.post(name: .showModelPicker, object: nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    chatViewModel.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Input bar (glass navigation layer)

    private var inputBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Message…", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .onSubmit { send(); isInputFocused = true }

                if chatViewModel.isGenerating {
                    Button(action: chatViewModel.stopGenerating) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(canSend ? Color.accentColor : Color(.separatorColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text("What can I help you with?")
                .font(.title3)
                .foregroundStyle(.secondary)

            if mlxService.isReady, let id = mlxService.activeModelId {
                Text(id.components(separatedBy: "/").last ?? id)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if !mlxService.isLoading {
                let quickLoadId = mlxService.lastUsedModelId
                    ?? modelManager.mlxModels.first?.id

                if let modelId = quickLoadId {
                    Button {
                        Task { try? await mlxService.loadModel(id: modelId) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Load \(modelId.components(separatedBy: "/").last ?? modelId)")
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }

                Button {
                    NotificationCenter.default.post(name: .showModelPicker, object: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                        Text(quickLoadId != nil ? "Browse models" : "Choose a model to get started")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, quickLoadId != nil ? 2 : 4)
            }

            if case .loading = mlxService.loadState {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading model…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }

            if case .downloading(let progress) = mlxService.loadState {
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                    Text("Downloading… \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }

            if case .error(let msg) = mlxService.loadState {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let id = sortedMessages.last?.id {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    // MARK: - Actions

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatViewModel.isGenerating
            && mlxService.isReady
    }

    private func send() {
        guard canSend else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        let userMessage = Message(role: .user, content: trimmed)
        conversation.messages.append(userMessage)
        conversation.updatedAt = .now
        if conversation.title == "New Chat" {
            conversation.title = String(trimmed.prefix(40))
        }
        try? modelContext.save()
        draft = ""

        chatViewModel.send(
            message: trimmed,
            conversation: conversation,
            mlxService: mlxService,
            modelContext: modelContext
        )
    }
}

// MARK: - Streaming message (isolates per-token observation)

private struct StreamingMessageBubble: View {
    let message: Message
    var chatViewModel: ChatViewModel

    var body: some View {
        MessageBubble(
            message: message,
            isStreaming: true,
            contentOverride: chatViewModel.streamingContent.isEmpty ? nil : chatViewModel.streamingContent
        )
    }
}

// MARK: - Scroll trigger (isolates streamingContent observation from ChatView)

private struct StreamingScrollTrigger: View {
    var chatViewModel: ChatViewModel
    let lastMessageId: UUID?
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: chatViewModel.streamingContent) {
                if let id = lastMessageId {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
    }
}
