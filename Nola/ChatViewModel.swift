import Foundation
import MLX
import MLXLMCommon
import SwiftData
import SwiftUI

@Observable
@MainActor
final class ChatViewModel {
    var streamingContent = ""
    var streamingThinkingContent = ""
    var isGenerating = false
    var generationError: GenerationError?
    var thinkingEnabled = false
    var isThinking = false
    var thinkingElapsed: Double = 0

    private var generationTask: Task<Void, Never>?
    private var rawAccumulator = ""
    private var isInThinkingPhase = false
    private var thinkingStartTime: ContinuousClock.Instant?
    private var thinkingDuration: Duration?
    private var modelSupportsThinking = false

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
        modelContext: SwiftData.ModelContext,
        modelSupportsThinking supportsThinking: Bool = false
    ) {
        guard let container = mlxService.container else { return }

        let assistantMessage = Message(role: .assistant, content: "")
        assistantMessage.conversation = conversation
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        isGenerating = true
        streamingContent = ""
        streamingThinkingContent = ""
        rawAccumulator = ""
        isInThinkingPhase = false
        isThinking = false
        thinkingElapsed = 0
        thinkingStartTime = nil
        thinkingDuration = nil
        modelSupportsThinking = supportsThinking
        generationError = nil

        conversation.modelId = mlxService.activeModelId
        let chatMessages = buildChatMessages(from: conversation)
        let thinking = thinkingEnabled

        generationTask = Task {
            let startTime = ContinuousClock.now
            var tokenCount = 0
            do {
                let stream = mlxService.generate(
                    messages: chatMessages,
                    container: container,
                    enableThinking: thinking
                )
                for try await chunk in stream {
                    tokenCount += 1
                    processChunk(chunk)
                }

                assistantMessage.content = streamingContent
                if !streamingThinkingContent.isEmpty {
                    assistantMessage.thinkingContent = streamingThinkingContent
                    assistantMessage.thinkingSeconds = thinkingElapsed
                }
                let elapsed = ContinuousClock.now - startTime
                let (seconds, attoseconds) = elapsed.components
                assistantMessage.generationSeconds = Double(seconds) + Double(attoseconds) / 1e18
                assistantMessage.tokenCount = tokenCount
                assistantMessage.memoryBytesUsed = Memory.activeMemory + Memory.cacheMemory
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
            isThinking = false
            streamingContent = ""
        }
    }

    private func processChunk(_ chunk: String) {
        rawAccumulator += chunk

        // Already found </think> — just update the response portion
        if !isInThinkingPhase, thinkingDuration != nil {
            streamingContent = responseFromRaw()
            return
        }

        // Check for </think> in accumulated output
        if let endRange = rawAccumulator.range(of: "</think>") {
            isInThinkingPhase = false
            isThinking = false
            if let start = thinkingStartTime {
                thinkingDuration = ContinuousClock.now - start
                let (s, a) = thinkingDuration!.components
                thinkingElapsed = Double(s) + Double(a) / 1e18
            }
            // Final thinking content (strip <think> tag if present)
            var thinking = String(rawAccumulator[..<endRange.lowerBound])
            if let tagRange = thinking.range(of: "<think>") {
                thinking = String(thinking[tagRange.upperBound...])
            }
            streamingThinkingContent = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            streamingContent = responseFromRaw()
            return
        }

        // No </think> yet — if the model supports thinking, stream thinking content live
        if modelSupportsThinking {
            if !isInThinkingPhase {
                isInThinkingPhase = true
                isThinking = true
                if thinkingStartTime == nil { thinkingStartTime = .now }
            }
            // Update live thinking content for display
            var thinking = rawAccumulator
            if let tagRange = thinking.range(of: "<think>") {
                thinking = String(thinking[tagRange.upperBound...])
            }
            streamingThinkingContent = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        // Non-thinking model — direct pipe
        streamingContent = rawAccumulator
    }

    private func responseFromRaw() -> String {
        guard let endRange = rawAccumulator.range(of: "</think>") else {
            return rawAccumulator
        }
        return String(rawAccumulator[endRange.upperBound...])
            .trimmingCharacters(in: .newlines)
    }

    func stopGenerating() {
        generationTask?.cancel()
        generationTask = nil
    }

    func dismissError() {
        generationError = nil
    }

    private func buildChatMessages(from conversation: Conversation) -> [Chat.Message] {
        // Thinking is handled via additionalContext["enable_thinking"],
        // not via system prompt — the model's chat template handles it natively.
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
