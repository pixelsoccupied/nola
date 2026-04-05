import Foundation

struct HFModelInfo: Codable, Identifiable, Hashable {
    let id: String
    let author: String?
    let downloads: Int?
    let tags: [String]?
    let pipelineTag: String?
    let lastModified: String?

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case downloads
        case tags
        case pipelineTag = "pipeline_tag"
        case lastModified
    }

    var displayName: String {
        id.components(separatedBy: "/").last ?? id
    }

    private static let paramRegex = try! NSRegularExpression(pattern: #"[\-_](\d+\.?\d*)[bB][\-_\.]"#)
    private static let fallbackParamRegex = try! NSRegularExpression(pattern: #"(\d+\.?\d*)b"#)
    private static let tagParamRegex = try! NSRegularExpression(pattern: #"^(\d+\.?\d*)b$"#)

    var parameterBillions: Double? {
        let name = displayName.lowercased()

        for r in [Self.paramRegex, Self.fallbackParamRegex] {
            if let match = r.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
               let range = Range(match.range(at: 1), in: name),
               let value = Double(name[range]),
               value > 0 && value < 1000 {
                return value
            }
        }

        if let tags {
            for tag in tags {
                let t = tag.lowercased()
                if let match = Self.tagParamRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                   let range = Range(match.range(at: 1), in: t),
                   let value = Double(t[range]) {
                    return value
                }
            }
        }

        return nil
    }

    var parameterSize: String? {
        guard let b = parameterBillions else { return nil }
        if b < 1 { return String(format: "%.1fB", b) }
        if b == floor(b) { return "\(Int(b))B" }
        return String(format: "%.1fB", b)
    }

    /// Estimated memory needed to run this model (rough: ~0.6 GB per billion params for 4-bit)
    var estimatedMemoryGB: Double? {
        guard let b = parameterBillions else { return nil }
        let is4Bit = displayName.lowercased().contains("4bit")
        let is8Bit = displayName.lowercased().contains("8bit")
        if is4Bit { return b * 0.6 }
        if is8Bit { return b * 1.1 }
        return b * 0.6 // assume 4-bit for mlx-community
    }

    func fitsInMemory(_ availableGB: Double) -> Bool {
        guard let needed = estimatedMemoryGB else { return true }
        return needed < availableGB * 0.75 // leave 25% headroom
    }

    // MARK: - Family grouping

    private static let quantSuffixes = ["bf16", "8bit", "6bit", "5bit", "4bit", "mxfp8", "mxfp4", "nvfp4"]

    /// Quality ordering: lower = higher quality
    private static let quantQuality: [String: Int] = [
        "bf16": 0, "8bit": 1, "mxfp8": 2, "6bit": 3, "5bit": 4, "4bit": 5, "mxfp4": 6, "nvfp4": 7
    ]

    var familyName: String {
        let name = displayName.lowercased()
        for suffix in Self.quantSuffixes {
            if name.hasSuffix("-\(suffix)") {
                return String(displayName.dropLast(suffix.count + 1))
            }
        }
        return displayName
    }

    var quantLabel: String? {
        let name = displayName.lowercased()
        for suffix in Self.quantSuffixes {
            if name.hasSuffix("-\(suffix)") { return suffix }
        }
        return nil
    }

    var quantQualityRank: Int {
        guard let q = quantLabel else { return 99 }
        return Self.quantQuality[q] ?? 99
    }

    static func groupByFamily(_ models: [HFModelInfo]) -> [ModelFamily] {
        var familyOrder: [String] = []
        var familyMap: [String: [HFModelInfo]] = [:]
        for model in models {
            let key = model.familyName
            if familyMap[key] == nil { familyOrder.append(key) }
            familyMap[key, default: []].append(model)
        }
        return familyOrder.compactMap { key in
            guard let variants = familyMap[key] else { return nil }
            return ModelFamily(
                name: key,
                variants: variants.sorted { $0.quantQualityRank < $1.quantQualityRank }
            )
        }
    }
}

struct ModelFamily: Identifiable {
    let name: String
    let variants: [HFModelInfo]

    var id: String { name }

    var displayName: String { name }

    var bestDownloads: Int {
        variants.compactMap(\.downloads).max() ?? 0
    }

    var parameterSize: String? {
        variants.first?.parameterSize
    }

    func recommended(memoryGB: Double) -> HFModelInfo? {
        variants.first { $0.fitsInMemory(memoryGB) }
    }

    /// Auto-detect model line from name: "gemma-4-31b-it" → "Gemma"
    var modelLine: String {
        let first = name.components(separatedBy: CharacterSet(charactersIn: "-_")).first ?? name
        // Strip trailing digits: "Qwen3" → "Qwen", "SmolLM3" → "SmolLM"
        let stripped = first.replacingOccurrences(
            of: #"\d+\.?\d*$"#, with: "", options: .regularExpression
        )
        let base = stripped.isEmpty ? first : stripped
        // Capitalize first letter, preserve rest (e.g. "deepseek" → "Deepseek", "GLM" → "GLM")
        return base.prefix(1).uppercased() + base.dropFirst()
    }
}

struct ModelLineGroup: Identifiable {
    let name: String
    let families: [ModelFamily]
    var id: String { name }

    static func from(_ families: [ModelFamily]) -> [ModelLineGroup] {
        var order: [String] = []
        var map: [String: [ModelFamily]] = [:]
        for family in families {
            let line = family.modelLine
            if map[line] == nil { order.append(line) }
            map[line, default: []].append(family)
        }
        return order.compactMap { line in
            guard let fams = map[line] else { return nil }
            return ModelLineGroup(name: line, families: fams)
        }
    }
}

enum DeviceCapability {
    static var unifiedMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

}
