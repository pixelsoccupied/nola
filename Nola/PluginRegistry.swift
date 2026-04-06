import Foundation

struct PluginDefinition: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let npmPackage: String
    let extraArgs: [String]
    let requiresApiKey: String?
    let apiKeyEnvVar: String?

    var command: [String] {
        [npmPackage] + extraArgs
    }
}

enum PluginRegistry {
    static let plugins: [PluginDefinition] = [
        PluginDefinition(
            id: "applescript",
            name: "AppleScript",
            description: "Control macOS apps like Mail, Calendar, Finder, and Safari",
            icon: "applescript",
            npmPackage: "@peakmojo/applescript-mcp",
            extraArgs: [],
            requiresApiKey: nil,
            apiKeyEnvVar: nil
        ),
        PluginDefinition(
            id: "filesystem",
            name: "File System",
            description: "Read, search, and manage files on your Mac",
            icon: "folder",
            npmPackage: "@modelcontextprotocol/server-filesystem",
            extraArgs: ["~/Documents", "~/Desktop", "~/Downloads"],
            requiresApiKey: nil,
            apiKeyEnvVar: nil
        ),
        PluginDefinition(
            id: "fetch",
            name: "Web Fetch",
            description: "Fetch and read web pages",
            icon: "globe",
            npmPackage: "@modelcontextprotocol/server-fetch",
            extraArgs: [],
            requiresApiKey: nil,
            apiKeyEnvVar: nil
        ),
        PluginDefinition(
            id: "brave-search",
            name: "Brave Search",
            description: "Search the web using Brave Search",
            icon: "magnifyingglass",
            npmPackage: "@anthropic-ai/brave-search-mcp",
            extraArgs: [],
            requiresApiKey: "Brave Search API Key",
            apiKeyEnvVar: "BRAVE_API_KEY"
        ),
        PluginDefinition(
            id: "memory",
            name: "Memory",
            description: "Remember things across conversations using a knowledge graph",
            icon: "brain.head.profile",
            npmPackage: "@modelcontextprotocol/server-memory",
            extraArgs: [],
            requiresApiKey: nil,
            apiKeyEnvVar: nil
        ),
    ]

    static func plugin(for id: String) -> PluginDefinition? {
        plugins.first { $0.id == id }
    }
}
