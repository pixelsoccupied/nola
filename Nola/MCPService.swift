import Foundation
import MCP
import MLXLMCommon
import os
import System
import Tokenizers

private let mcpLog = os.Logger(subsystem: "com.nola.app", category: "MCPService")

@Observable
@MainActor
final class MCPService {

    enum PluginState: Sendable {
        case idle
        case starting
        case ready(toolCount: Int)
        case error(String)
    }

    struct ToolInfo: Sendable {
        let pluginId: String
        let name: String
        let spec: ToolSpec
    }

    // MARK: - Persisted state

    private static let enabledKey = "enabledPluginIds"
    private static let apiKeysKey = "pluginApiKeys"

    var enabledPlugins: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? [])
    }()

    var apiKeys: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: apiKeysKey) as? [String: String]) ?? [:]
    }()

    // MARK: - Runtime state

    var pluginStates: [String: PluginState] = [:]
    private(set) var allTools: [ToolInfo] = []
    private var connections: [String: MCPConnection] = [:]
    var npxPath: String?

    var allToolSpecs: [ToolSpec] {
        allTools.map { $0.spec as ToolSpec }
    }

    var isAnyPluginReady: Bool {
        pluginStates.values.contains { if case .ready = $0 { return true }; return false }
    }

    // MARK: - Plugin management

    func enablePlugin(_ id: String) {
        enabledPlugins.insert(id)
        UserDefaults.standard.set(Array(enabledPlugins), forKey: Self.enabledKey)
        Task { await startServer(for: id) }
    }

    func disablePlugin(_ id: String) {
        enabledPlugins.remove(id)
        UserDefaults.standard.set(Array(enabledPlugins), forKey: Self.enabledKey)
        Task { await stopServer(for: id) }
    }

    func setApiKey(_ key: String, for pluginId: String) {
        apiKeys[pluginId] = key
        UserDefaults.standard.set(apiKeys, forKey: Self.apiKeysKey)
    }

    // MARK: - Server lifecycle

    func ensureServersRunning() async {
        if npxPath == nil {
            npxPath = Self.detectNpx()
        }
        guard npxPath != nil else { return }

        for pluginId in enabledPlugins {
            if connections[pluginId] == nil {
                await startServer(for: pluginId)
            }
        }
    }

    private func startServer(for pluginId: String) async {
        if npxPath == nil { npxPath = Self.detectNpx() }
        guard let plugin = PluginRegistry.plugin(for: pluginId),
              let npx = npxPath else { return }

        // Check API key requirement
        if plugin.apiKeyEnvVar != nil, (apiKeys[pluginId] ?? "").isEmpty {
            pluginStates[pluginId] = .error("API key required")
            return
        }

        pluginStates[pluginId] = .starting
        mcpLog.info("Starting MCP server: \(pluginId)")

        // Capture what we need before leaving MainActor
        let command = plugin.command
        let apiKeyEnvVar = plugin.apiKeyEnvVar
        let apiKey = apiKeys[pluginId]

        do {
            let connection = try await Self.launchServer(
                command: command, npxPath: npx,
                apiKeyEnvVar: apiKeyEnvVar, apiKey: apiKey
            )
            connections[pluginId] = connection

            // Discover tools
            let (tools, _) = try await connection.client.listTools()
            let toolInfos = tools.map { mcpTool in
                ToolInfo(
                    pluginId: pluginId,
                    name: mcpTool.name,
                    spec: Self.convertToToolSpec(mcpTool)
                )
            }

            // Remove old tools for this plugin, add new ones
            allTools.removeAll { $0.pluginId == pluginId }
            allTools.append(contentsOf: toolInfos)

            pluginStates[pluginId] = .ready(toolCount: tools.count)
            mcpLog.info("MCP server ready: \(pluginId) with \(tools.count) tools")
        } catch {
            pluginStates[pluginId] = .error(error.localizedDescription)
            mcpLog.error("Failed to start MCP server \(pluginId): \(error.localizedDescription)")
        }
    }

    private func stopServer(for pluginId: String) async {
        if let connection = connections.removeValue(forKey: pluginId) {
            await connection.client.disconnect()
            connection.process.terminate()
        }
        allTools.removeAll { $0.pluginId == pluginId }
        pluginStates[pluginId] = .idle
    }

    func shutdownAll() {
        for (id, connection) in connections {
            connection.process.terminate()
            mcpLog.info("Terminated MCP server: \(id)")
        }
        connections.removeAll()
        allTools.removeAll()
    }

    // MARK: - Tool execution

    func callTool(name: String, arguments: [String: JSONValue]) async throws -> String {
        guard let toolInfo = allTools.first(where: { $0.name == name }),
              let connection = connections[toolInfo.pluginId] else {
            throw MCPServiceError.toolNotFound(name)
        }

        mcpLog.info("Calling tool: \(name)")
        let mcpArgs = arguments.mapValues { Self.convertToMCPValue($0) }
        let (content, isError) = try await connection.client.callTool(
            name: name, arguments: mcpArgs
        )

        let result = Self.extractResultText(from: content)
        if isError == true {
            mcpLog.warning("Tool \(name) returned error: \(result)")
        }
        return result
    }

    // MARK: - Process launching

    private struct MCPConnection: @unchecked Sendable {
        let process: Process
        let client: Client
    }

    nonisolated private static func launchServer(
        command: [String], npxPath: String,
        apiKeyEnvVar: String?, apiKey: String?
    ) async throws -> MCPConnection {
        let serverIn = Pipe()   // we write → server reads
        let serverOut = Pipe()  // server writes → we read
        let serverErr = Pipe()  // capture stderr for debugging

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npxPath)
        process.arguments = ["-y"] + command
        process.standardInput = serverIn
        process.standardOutput = serverOut
        process.standardError = serverErr

        // GUI apps don't inherit shell PATH — set it explicitly
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        if let envVar = apiKeyEnvVar, let key = apiKey {
            env[envVar] = key
        }
        process.environment = env

        try process.run()

        // Log stderr in background for debugging
        let errPipe = serverErr
        Task.detached {
            let stderrLog = os.Logger(subsystem: "com.nola.app", category: "MCPService")
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                stderrLog.debug("MCP stderr: \(str)")
            }
        }

        // Create MCP client over stdio piped to subprocess
        let readFD = serverOut.fileHandleForReading.fileDescriptor
        let writeFD = serverIn.fileHandleForWriting.fileDescriptor
        let transport = StdioTransport(
            input: .init(rawValue: readFD),
            output: .init(rawValue: writeFD)
        )

        let client = Client(name: "Nola", version: "1.0.0")
        _ = try await client.connect(transport: transport)

        return MCPConnection(process: process, client: client)
    }

    // MARK: - npx detection

    nonisolated static func detectNpx() -> String? {
        let candidates = [
            "/opt/homebrew/bin/npx",
            "/usr/local/bin/npx",
            "/usr/bin/npx",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: try `which npx` in a shell
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which npx"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return nil
    }

    // MARK: - Type conversions

    /// MCP Tool → ToolSpec ([String: any Sendable])
    nonisolated private static func convertToToolSpec(_ tool: MCP.Tool) -> ToolSpec {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description ?? "",
                "parameters": convertValueToDict(tool.inputSchema),
            ] as [String: any Sendable],
        ]
    }

    /// MCP Value (JSON Schema) → [String: any Sendable]
    nonisolated private static func convertValueToDict(_ value: MCP.Value) -> [String: any Sendable] {
        switch value {
        case .object(let dict):
            var result: [String: any Sendable] = [:]
            for (key, val) in dict {
                result[key] = convertValueToAny(val)
            }
            return result
        default:
            return [:]
        }
    }

    nonisolated private static func convertValueToAny(_ value: MCP.Value) -> any Sendable {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(_, let d): return d
        case .array(let arr): return arr.map { convertValueToAny($0) }
        case .object(let dict):
            var result: [String: any Sendable] = [:]
            for (key, val) in dict {
                result[key] = convertValueToAny(val)
            }
            return result
        }
    }

    /// MLXLMCommon JSONValue → MCP Value
    nonisolated private static func convertToMCPValue(_ jsonValue: JSONValue) -> MCP.Value {
        switch jsonValue {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let arr): return .array(arr.map { convertToMCPValue($0) })
        case .object(let dict): return .object(dict.mapValues { convertToMCPValue($0) })
        }
    }

    /// MCP tool result → String for Chat.Message.tool()
    nonisolated private static func extractResultText(from content: [MCP.Tool.Content]) -> String {
        content.compactMap { item in
            switch item {
            case .text(let text, _, _): return text
            case .image(_, let mimeType, _, _): return "[Image: \(mimeType)]"
            case .audio(_, let mimeType, _, _): return "[Audio: \(mimeType)]"
            case .resource(let resource, _, _): return "[Resource: \(resource)]"
            default: return nil
            }
        }.joined(separator: "\n")
    }
}

enum MCPServiceError: LocalizedError {
    case toolNotFound(String)
    case npxNotFound

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool '\(name)' not found in any connected plugin"
        case .npxNotFound:
            return "Node.js (npx) not found. Install it to use plugins."
        }
    }
}
