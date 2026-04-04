import Foundation

actor HuggingFaceService {
    private let baseURL = "https://huggingface.co/api/models"
    private let cacheDuration: TimeInterval = 600 // 10 minutes

    func fetchModels(
        author: String = "mlx-community",
        search: String? = nil,
        sort: SortOption = .trending,
        limit: Int = 100
    ) async throws -> [HFModelInfo] {
        let cacheKey = "\(sort.rawValue):\(search ?? "")"
        if let entry = cache[cacheKey],
           Date().timeIntervalSince(entry.timestamp) < cacheDuration {
            return entry.models
        }

        var components = URLComponents(string: baseURL)!
        var queryItems = [
            URLQueryItem(name: "author", value: author),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "library", value: "mlx"),
        ]
        if let search, !search.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let models = try JSONDecoder().decode([HFModelInfo].self, from: data)

        // Cap cache size — keep default + recent searches, evict oldest
        if cache.count > 10 {
            let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }
            if let key = oldest?.key { cache.removeValue(forKey: key) }
        }
        cache[cacheKey] = CacheEntry(models: models, timestamp: Date())

        return models
    }

    private struct CacheEntry {
        let models: [HFModelInfo]
        let timestamp: Date
    }

    private var cache: [String: CacheEntry] = [:]

    enum SortOption: String, CaseIterable {
        case trending = "trendingScore"
        case newest = "lastModified"
        case popular = "downloads"

        var label: String {
            switch self {
            case .trending: return "Trending"
            case .newest: return "New"
            case .popular: return "Popular"
            }
        }
    }
}
