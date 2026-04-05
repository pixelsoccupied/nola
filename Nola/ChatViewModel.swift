import Foundation
import MLXLMCommon
import SwiftData
import SwiftUI

@Observable
@MainActor
final class ChatViewModel {
    var streamingContent = ""
    var isGenerating = false
    var generationError: GenerationError?

    private var generationTask: Task<Void, Never>?

    struct GenerationError {
        let message: String
        let isModelIncompatible: Bool

        static func from(_ error: Error) -> GenerationError {
            let desc = error.localizedDescription
            if desc.contains("Jinja") || desc.contains("TemplateException") || desc.contains("chat_template") {
                return GenerationError(
                    message: "This model doesn't support chat conversations. Try a different model.",
                    isModelIncompatible: true
                )
            }
            if desc.contains("tokenizer") || desc.contains("Tokenizer") {
                return GenerationError(
                    message: "This model's tokenizer isn't compatible. Try a different model.",
                    isModelIncompatible: true
                )
            }
            return GenerationError(
                message: "Something went wrong: \(desc)",
                isModelIncompatible: false
            )
        }
    }

    func send(
        message: String,
        conversation: Conversation,
        mlxService: MLXService,
        modelContext: SwiftData.ModelContext
    ) {
        guard let container = mlxService.container else { return }

        let assistantMessage = Message(role: .assistant, content: "")
        assistantMessage.conversation = conversation
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        isGenerating = true
        streamingContent = ""
        generationError = nil

        conversation.modelId = mlxService.activeModelId
        let chatMessages = buildChatMessages(from: conversation)

        generationTask = Task {
            do {
                let stream = mlxService.generate(
                    messages: chatMessages,
                    container: container
                )
                for try await chunk in stream {
                    streamingContent += chunk
                }
                assistantMessage.content = streamingContent
            } catch {
                if Task.isCancelled {
                    assistantMessage.content = streamingContent + " [Cancelled]"
                } else {
                    generationError = GenerationError.from(error)
                    if assistantMessage.content.isEmpty && streamingContent.isEmpty {
                        conversation.messages.removeAll { $0.id == assistantMessage.id }
                        modelContext.delete(assistantMessage)
                    } else {
                        assistantMessage.content = streamingContent
                    }
                }
            }

            try? modelContext.save()
            isGenerating = false
            streamingContent = ""
        }
    }

    func stopGenerating() {
        generationTask?.cancel()
        generationTask = nil
    }

    func dismissError() {
        generationError = nil
    }

    private func buildChatMessages(from conversation: Conversation) -> [Chat.Message] {
        var messages: [Chat.Message] = [
            .system("You are a helpful assistant.")
        ]
        for msg in conversation.sortedMessages {
            if msg.role == .assistant && msg.content.isEmpty { continue }
            switch msg.role {
            case .user: messages.append(.user(msg.content))
            case .assistant: messages.append(.assistant(msg.content))
            case .system: break
            }
        }
        return messages
    }
}
