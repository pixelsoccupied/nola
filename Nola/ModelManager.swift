import Foundation
import SwiftUI

@Observable
@MainActor
final class ModelManager {
    private(set) var downloadedModels: [DownloadedModel] = []
    private(set) var mlxModels: [DownloadedModel] = []

    private let hfService = HuggingFaceService()
    private let cacheDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface")
    }()

    struct DownloadedModel: Identifiable, Hashable, Sendable {
        let id: String
        let path: URL
        let sizeBytes: Int64
        let supportsThinking: Bool      // model may emit <think> tags
        let thinkingControllable: Bool   // has enable_thinking flag (user can toggle)

        var displayName: String {
            id.components(separatedBy: "/").last ?? id
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    // MARK: - Scanning

    func scanDownloadedModels() async {
        let hubDir = cacheDirectory.appendingPathComponent("hub")
        let models = await Self.scanFileSystem(hubDir: hubDir)
        setModels(models)
    }

    func deleteModel(_ model: DownloadedModel) throws {
        try FileManager.default.removeItem(at: model.path)
        setModels(downloadedModels.filter { $0.id != model.id })
    }

    private func setModels(_ models: [DownloadedModel]) {
        downloadedModels = models
        mlxModels = models.filter { $0.id.hasPrefix("mlx-community/") }
    }

    func isDownloaded(_ modelId: String) -> Bool {
        downloadedModels.contains { $0.id == modelId }
    }

    // MARK: - HuggingFace API

    func fetchAvailableModels(
        search: String? = nil,
        sort: HuggingFaceService.SortOption = .trending
    ) async throws -> [HFModelInfo] {
        try await hfService.fetchModels(search: search, sort: sort)
    }

    // MARK: - File I/O (off main actor)

    nonisolated private static func scanFileSystem(hubDir: URL) async -> [DownloadedModel] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: hubDir.path) else { return [] }

        var models: [DownloadedModel] = []
        var seenIds: Set<String> = []
        for entry in entries where entry.hasPrefix("models--") {
            let parts = entry.replacingOccurrences(of: "models--", with: "")
                .components(separatedBy: "--")
            guard parts.count >= 2 else { continue }

            let modelId = parts.joined(separator: "/")
            guard !seenIds.contains(modelId) else { continue }

            let modelPath = hubDir.appendingPathComponent(entry)
            guard hasModelWeights(at: modelPath) else { continue }

            seenIds.insert(modelId)
            let size = directorySize(at: modelPath)
            let (thinks, controllable) = detectThinking(at: modelPath)
            models.append(DownloadedModel(id: modelId, path: modelPath, sizeBytes: size, supportsThinking: thinks, thinkingControllable: controllable))
        }
        return models.sorted { $0.id < $1.id }
    }

    nonisolated private static func hasModelWeights(at url: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        var hasWeights = false
        var hasConfig = false
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name.hasSuffix(".safetensors") { hasWeights = true }
            if name == "config.json" { hasConfig = true }
            if hasWeights && hasConfig { return true }
        }
        return false
    }

    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Returns (supportsThinking, thinkingControllable).
    /// - supportsThinking: model may emit <think> tags (for parser)
    /// - thinkingControllable: has enable_thinking flag (user can toggle on/off)
    nonisolated private static func detectThinking(at modelPath: URL) -> (Bool, Bool) {
        let fm = FileManager.default
        let snapshotsDir = modelPath.appendingPathComponent("snapshots")
        guard let snapshots = try? fm.contentsOfDirectory(atPath: snapshotsDir.path),
              let hash = snapshots.first else { return (false, false) }

        let snapshotDir = snapshotsDir.appendingPathComponent(hash)

        // Check chat_template.jinja first (preferred by swift-transformers)
        let jinjaFile = snapshotDir.appendingPathComponent("chat_template.jinja")
        if let content = try? String(contentsOf: jinjaFile, encoding: .utf8),
           content.contains("<think>") {
            return (true, content.contains("enable_thinking"))
        }

        // Fall back to tokenizer_config.json chat_template field
        let configFile = snapshotDir.appendingPathComponent("tokenizer_config.json")
        if let data = try? Data(contentsOf: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let template = json["chat_template"] as? String,
           template.contains("<think>") {
            return (true, template.contains("enable_thinking"))
        }

        return (false, false)
    }
}
