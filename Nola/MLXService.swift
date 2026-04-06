import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import os
import SwiftUI
import Tokenizers

private let mlxLog = Logger(subsystem: "com.nola.app", category: "MLXService")

@Observable
@MainActor
final class MLXService {

    enum LoadState: Sendable {
        case idle
        case loading
        case ready(ModelContainer)
        case error(String)
    }

    private static let lastModelKey = "lastUsedModelId"
    private static let incompatibleKey = "incompatibleModelIds"

    // Current model state — stays .ready during background downloads
    var loadState: LoadState = .idle
    var activeModelId: String?
    var loadingProgress: Double = 0

    // Background download tracking — separate from active model
    var downloadingModelId: String?
    var downloadingProgress: Double = 0

    // Completed download waiting to be activated
    private var pendingContainer: ModelContainer?
    var pendingModelId: String?

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
    private var downloadTask: Task<Void, Error>?

    var isReady: Bool {
        if case .ready = loadState { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = loadState { return true }
        return false
    }

    var isDownloading: Bool {
        downloadingModelId != nil
    }

    // MARK: - Model Loading

    func loadModel(id: String) async throws {
        let isLocal = await Self.modelExistsLocally(id: id)

        if isLocal {
            try await loadLocalModel(id: id)
        } else {
            try await downloadModel(id: id)
        }
    }

    private func loadLocalModel(id: String) async throws {
        // Cancel any in-progress local load (but NOT background downloads)
        loadTask?.cancel()
        loadTask = nil

        Memory.cacheLimit = 0
        Memory.cacheLimit = 20 * 1024 * 1024
        activeModelId = id
        loadState = .loading
        loadingProgress = 0

        mlxLog.info("Loading local model: \(id)")
        let configuration = ModelConfiguration(id: id)

        loadTask = Task {
            let container = try await LLMModelFactory.shared.loadContainer(
                hub: HubApi.default,
                configuration: configuration
            ) { progress in
                Task { @MainActor in
                    self.loadingProgress = progress.fractionCompleted
                }
                mlxLog.debug("Loading \(id): \(Int(progress.fractionCompleted * 100))%")
            }

            try Task.checkCancellation()
            mlxLog.info("Weights loaded for \(id), validating chat template…")

            let testMessages: [Chat.Message] = [.user("test")]
            _ = try await container.prepare(input: UserInput(chat: testMessages))

            mlxLog.info("Model ready: \(id)")
            loadState = .ready(container)
            loadingProgress = 0
            activeModelId = id
            UserDefaults.standard.set(id, forKey: Self.lastModelKey)
        }

        do {
            try await loadTask?.value
        } catch is CancellationError {
            mlxLog.info("Loading cancelled: \(id)")
            loadState = .idle
            loadingProgress = 0
        } catch {
            mlxLog.error("Loading failed for \(id): \(error.localizedDescription)")
            loadingProgress = 0
            handleLoadError(error, modelId: id)
            throw error
        }
    }

    private func downloadModel(id: String) async throws {
        // Cancel any in-progress download (but NOT the active model)
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModelId = id
        downloadingProgress = 0

        mlxLog.info("Downloading model: \(id)")
        let configuration = ModelConfiguration(id: id)

        downloadTask = Task {
            let container = try await LLMModelFactory.shared.loadContainer(
                hub: HubApi.default,
                configuration: configuration
            ) { progress in
                Task { @MainActor in
                    self.downloadingProgress = progress.fractionCompleted
                }
                mlxLog.debug("Downloading \(id): \(Int(progress.fractionCompleted * 100))%")
            }

            try Task.checkCancellation()
            mlxLog.info("Download complete for \(id), validating chat template…")

            let testMessages: [Chat.Message] = [.user("test")]
            _ = try await container.prepare(input: UserInput(chat: testMessages))

            mlxLog.info("Model validated and staged: \(id)")
            // Stage for user to activate
            downloadingModelId = nil
            downloadingProgress = 0
            pendingContainer = container
            pendingModelId = id
        }

        do {
            try await downloadTask?.value
        } catch is CancellationError {
            mlxLog.info("Download cancelled: \(id)")
            if downloadingModelId == id {
                downloadingModelId = nil
                downloadingProgress = 0
            }
        } catch {
            mlxLog.error("Download failed for \(id): \(error.localizedDescription)")
            if downloadingModelId == id {
                downloadingModelId = nil
                downloadingProgress = 0
            }
            handleLoadError(error, modelId: id)
            throw error
        }
    }

    private func handleLoadError(_ error: Error, modelId: String) {
        let desc = error.localizedDescription
        if desc.contains("Jinja") || desc.contains("TemplateException") || desc.contains("chat_template") || desc.contains("tokenizer") {
            markIncompatible(modelId)
            loadState = .error("This model doesn't support chat. Try a different variant.")
        } else {
            loadState = .error(desc)
        }
    }

    func activatePendingModel() {
        guard let container = pendingContainer, let id = pendingModelId else { return }
        Memory.cacheLimit = 0
        Memory.cacheLimit = 20 * 1024 * 1024
        loadState = .ready(container)
        activeModelId = id
        UserDefaults.standard.set(id, forKey: Self.lastModelKey)
        pendingContainer = nil
        pendingModelId = nil
    }

    func dismissPendingModel() {
        pendingContainer = nil
        pendingModelId = nil
    }

    func cancelLoading() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModelId = nil
        downloadingProgress = 0
    }

    // MARK: - Generation

    func generate(
        messages: [Chat.Message],
        container: ModelContainer,
        enableThinking: Bool = false,
        tools: [ToolSpec]? = nil,
        maxTokens: Int = 2048,
        temperature: Float = 0.7
    ) -> AsyncThrowingStream<Generation, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let userInput = UserInput(
                        chat: messages,
                        tools: tools,
                        additionalContext: ["enable_thinking": enableThinking]
                    )
                    let parameters = GenerateParameters(
                        maxTokens: maxTokens,
                        temperature: temperature
                    )

                    let lmInput = try await container.prepare(input: userInput)
                    let stream = try await container.generate(
                        input: lmInput, parameters: parameters)

                    for await generation in stream {
                        try Task.checkCancellation()
                        continuation.yield(generation)
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
