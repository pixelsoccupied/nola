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
    var toolCallActivity: [ToolCallRecord] = []

    private var generationTask: Task<Void, Never>?
    private var rawAccumulator = ""
    private var isInThinkingPhase = false
    private var thinkingStartTime: ContinuousClock.Instant?
    private var thinkingDuration: Duration?
    private var modelSupportsThinking = false

    struct ToolCallRecord: Identifiable {
        let id = UUID()
        let name: String
        let arguments: String
        var status: Status

        enum Status {
            case running
            case completed(String)
            case failed(String)
        }
    }

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
        mcpService: MCPService? = nil,
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
        toolCallActivity = []

        conversation.modelId = mlxService.activeModelId
        var chatMessages = buildChatMessages(from: conversation)
        let thinking = thinkingEnabled
        let hasEnabledPlugins = mcpService?.enabledPlugins.isEmpty == false

        generationTask = Task {
            let startTime = ContinuousClock.now
            var tokenCount = 0
            var toolRound = 0
            let maxToolRounds = 3

            // Start MCP servers if any plugins are enabled, then collect tools
            if hasEnabledPlugins {
                await mcpService?.ensureServersRunning()
            }
            let toolSpecs = mcpService?.isAnyPluginReady == true ? mcpService?.allToolSpecs : nil

            do {
                // Generation loop — restarts after tool calls
                generateLoop: while toolRound <= maxToolRounds {
                    var pendingToolCalls: [ToolCall] = []

                    let stream = mlxService.generate(
                        messages: chatMessages,
                        container: container,
                        enableThinking: thinking,
                        tools: toolSpecs
                    )
                    for try await generation in stream {
                        switch generation {
                        case .chunk(let chunk):
                            tokenCount += 1
                            processChunk(chunk)
                        case .toolCall(let toolCall):
                            pendingToolCalls.append(toolCall)
                        case .info:
                            break
                        }
                    }

                    // No tool calls — generation is done
                    if pendingToolCalls.isEmpty {
                        break generateLoop
                    }

                    // Execute tool calls and feed results back
                    guard let mcp = mcpService else { break generateLoop }
                    toolRound += 1

                    for toolCall in pendingToolCalls {
                        let argsJSON = toolCall.function.arguments.mapValues { "\($0)" }
                        let argsString = (try? String(
                            data: JSONSerialization.data(
                                withJSONObject: argsJSON, options: .fragmentsAllowed),
                            encoding: .utf8)) ?? "{}"

                        let record = ToolCallRecord(
                            name: toolCall.function.name,
                            arguments: argsString,
                            status: .running
                        )
                        toolCallActivity.append(record)
                        let recordIndex = toolCallActivity.count - 1

                        do {
                            let result = try await mcp.callTool(
                                name: toolCall.function.name,
                                arguments: toolCall.function.arguments
                            )
                            toolCallActivity[recordIndex].status = .completed(result)
                            chatMessages.append(.tool(result))
                        } catch {
                            let errMsg = error.localizedDescription
                            toolCallActivity[recordIndex].status = .failed(errMsg)
                            chatMessages.append(.tool("Error: \(errMsg)"))
                        }
                    }

                    // Reset streaming state for next generation pass
                    rawAccumulator = ""
                    streamingContent = ""
                    isInThinkingPhase = false
                    thinkingDuration = nil
                }

                // If response is empty but we had tool calls, show a fallback
                if streamingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !toolCallActivity.isEmpty {
                    streamingContent = "Tool calls completed but the model didn't generate a response. Try rephrasing your question."
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

                // Persist tool call records
                if !toolCallActivity.isEmpty {
                    assistantMessage.toolCallsJSON = encodeToolCalls(toolCallActivity)
                }
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

    private func encodeToolCalls(_ records: [ToolCallRecord]) -> String? {
        struct Encoded: Codable {
            let name: String
            let arguments: String
            let result: String?
            let error: String?
        }
        let encoded = records.map { record in
            switch record.status {
            case .running: return Encoded(name: record.name, arguments: record.arguments, result: nil, error: nil)
            case .completed(let r): return Encoded(name: record.name, arguments: record.arguments, result: r, error: nil)
            case .failed(let e): return Encoded(name: record.name, arguments: record.arguments, result: nil, error: e)
            }
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return nil }
        return String(data: data, encoding: .utf8)
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
