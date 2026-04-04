import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import SwiftUI

@Observable
@MainActor
final class MLXService {

    enum LoadState: Sendable {
        case idle
        case downloading(progress: Double)
        case loading
        case ready(ModelContainer)
        case error(String)
    }

    private static let lastModelKey = "lastUsedModelId"
    private static let incompatibleKey = "incompatibleModelIds"

    var loadState: LoadState = .idle
    var activeModelId: String?
    private(set) var incompatibleModels: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: incompatibleKey) ?? [])
    }()

    func isIncompatible(_ modelId: String) -> Bool {
        incompatibleModels.contains(modelId)
    }

    private func markIncompatible(_ modelId: String) {
        incompatibleModels.insert(modelId)
        UserDefaults.standard.set(Array(incompatibleModels), forKey: Self.incompatibleKey)
    }

    var lastUsedModelId: String? {
        UserDefaults.standard.string(forKey: Self.lastModelKey)
    }

    private var loadTask: Task<Void, Error>?

    var isReady: Bool {
        if case .ready = loadState { return true }
        return false
    }

    var isLoading: Bool {
        switch loadState {
        case .downloading, .loading: return true
        default: return false
        }
    }

    // MARK: - Model Loading

    func loadModel(id: String) async throws {
        // Cancel any in-progress load
        loadTask?.cancel()
        loadTask = nil

        // Evict previous model from memory — only one loaded at a time
        Memory.cacheLimit = 0  // flush GPU memory pool
        Memory.cacheLimit = 20 * 1024 * 1024  // restore reasonable cache

        activeModelId = id
        let isLocal = await Self.modelExistsLocally(id: id)
        loadState = isLocal ? .loading : .downloading(progress: 0)
        Memory.cacheLimit = 20 * 1024 * 1024

        let configuration = ModelConfiguration(id: id)

        loadTask = Task {
            let container = try await LLMModelFactory.shared.loadContainer(
                hub: HubApi.default,
                configuration: configuration
            ) { progress in
                Task { @MainActor in
                    if !isLocal {
                        self.loadState = .downloading(progress: progress.fractionCompleted)
                    }
                }
            }

            try Task.checkCancellation()

            // Validate chat template before marking ready
            let testMessages: [Chat.Message] = [.user("test")]
            let testInput = UserInput(chat: testMessages)
            _ = try await container.prepare(input: testInput)

            loadState = .ready(container)
            activeModelId = id
            UserDefaults.standard.set(id, forKey: Self.lastModelKey)
        }

        do {
            try await loadTask?.value
        } catch is CancellationError {
            loadState = .idle
        } catch {
            let desc = error.localizedDescription
            if desc.contains("Jinja") || desc.contains("TemplateException") || desc.contains("chat_template") || desc.contains("tokenizer") {
                markIncompatible(id)
                loadState = .error("This model doesn't support chat. Try a different variant.")
            } else {
                loadState = .error(desc)
            }
            throw error
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        loadState = .idle
        activeModelId = nil
    }

    // MARK: - Generation

    func generate(
        messages: [Chat.Message],
        container: ModelContainer,
        maxTokens: Int = 2048,
        temperature: Float = 0.7
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let userInput = UserInput(chat: messages)
                    let parameters = GenerateParameters(
                        maxTokens: maxTokens,
                        temperature: temperature
                    )

                    let lmInput = try await container.prepare(input: userInput)
                    let stream = try await container.generate(
                        input: lmInput, parameters: parameters)

                    for await generation in stream {
                        try Task.checkCancellation()
                        if let chunk = generation.chunk {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Convenience

    var container: ModelContainer? {
        if case .ready(let container) = loadState {
            return container
        }
        return nil
    }

    nonisolated private static func modelExistsLocally(id: String) async -> Bool {
        let dirName = "models--" + id.replacingOccurrences(of: "/", with: "--")
        let modelDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(dirName)

        guard let enumerator = FileManager.default.enumerator(
            at: modelDir, includingPropertiesForKeys: nil
        ) else { return false }

        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.lastPathComponent.hasSuffix(".safetensors") {
                return true
            }
        }
        return false
    }
}

extension HubApi {
    @MainActor
    static let `default` = HubApi(
        downloadBase: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface")
    )
}
