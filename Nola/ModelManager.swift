import Foundation
import SwiftUI

@Observable
@MainActor
final class ModelManager {
    private(set) var downloadedModels: [DownloadedModel] = []
    private(set) var mlxModels: [DownloadedModel] = []
    var isScanning = false

    private let hfService = HuggingFaceService()
    private let cacheDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface")
    }()

    struct DownloadedModel: Identifiable, Hashable, Sendable {
        let id: String
        let path: URL
        let sizeBytes: Int64

        var displayName: String {
            id.components(separatedBy: "/").last ?? id
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    // MARK: - Scanning

    func scanDownloadedModels() async {
        isScanning = true
        let hubDir = cacheDirectory.appendingPathComponent("hub")
        let models = await Self.scanFileSystem(hubDir: hubDir)
        setModels(models)
        isScanning = false
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

    var totalStorageUsed: String {
        let total = downloadedModels.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
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
        for entry in entries where entry.hasPrefix("models--") {
            let parts = entry.replacingOccurrences(of: "models--", with: "")
                .components(separatedBy: "--")
            guard parts.count >= 2 else { continue }

            let modelId = parts.joined(separator: "/")
            let modelPath = hubDir.appendingPathComponent(entry)

            guard hasModelWeights(at: modelPath) else { continue }

            let size = directorySize(at: modelPath)
            models.append(DownloadedModel(id: modelId, path: modelPath, sizeBytes: size))
        }
        return models.sorted { $0.id < $1.id }
    }

    nonisolated private static func hasModelWeights(at url: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasSuffix(".safetensors") {
                return true
            }
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
}
