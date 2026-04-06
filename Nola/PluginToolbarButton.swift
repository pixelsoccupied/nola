import SwiftUI

struct PluginToolbarButton: View {
    @Environment(MCPService.self) private var mcpService
    @State private var showBrowser = false

    private var isStarting: Bool {
        mcpService.pluginStates.values.contains { if case .starting = $0 { return true }; return false }
    }

    var body: some View {
        Button { showBrowser = true } label: {
            Label("Plugins", systemImage: "puzzlepiece.extension")
                .labelStyle(.iconOnly)
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, options: .repeating, isActive: isStarting)
        }
        .help(helpText)
        .sheet(isPresented: $showBrowser) {
            PluginBrowserSheet()
        }
        .task {
            // Start any previously-enabled plugins on launch
            if mcpService.npxPath == nil {
                mcpService.npxPath = MCPService.detectNpx()
            }
            if !mcpService.enabledPlugins.isEmpty {
                await mcpService.ensureServersRunning()
            }
        }
    }

    private var iconColor: Color {
        if mcpService.isAnyPluginReady {
            return .green
        } else if mcpService.enabledPlugins.isEmpty {
            return .secondary
        } else {
            return .accentColor
        }
    }

    private var helpText: String {
        if mcpService.isAnyPluginReady {
            let count = mcpService.allTools.count
            return "\(count) tool\(count == 1 ? "" : "s") available"
        }
        if isStarting { return "Starting plugins…" }
        return "Manage plugins"
    }
}
