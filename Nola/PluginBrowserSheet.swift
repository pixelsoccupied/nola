import SwiftUI

struct PluginBrowserSheet: View {
    @Environment(MCPService.self) private var mcpService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            runtimeBanner
            Divider()
            pluginList
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 400, idealHeight: 500)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plugins")
                    .font(.headline)
                Text("Extend what your model can do")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Runtime banner

    @ViewBuilder
    private var runtimeBanner: some View {
        let hasNpx = mcpService.npxPath != nil

        HStack(spacing: 10) {
            Image(systemName: hasNpx ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasNpx ? .green : .orange)
            if hasNpx {
                Text("Node.js detected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Node.js required")
                        .font(.subheadline)
                    Text("Install with: brew install node")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !hasNpx {
                Button("Install Guide") {
                    openURL(URL(string: "https://nodejs.org")!)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            (hasNpx ? Color.green : Color.orange).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Plugin list

    private var pluginList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(PluginRegistry.plugins) { plugin in
                    pluginRow(plugin)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Plugin row

    private func pluginRow(_ plugin: PluginDefinition) -> some View {
        let isEnabled = mcpService.enabledPlugins.contains(plugin.id)
        let state = mcpService.pluginStates[plugin.id] ?? .idle
        let hasNpx = mcpService.npxPath != nil
        let needsKey = plugin.requiresApiKey != nil
            && (mcpService.apiKeys[plugin.id] ?? "").isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: plugin.icon)
                    .font(.title3)
                    .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name)
                        .font(.body)
                    Text(plugin.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                statusBadge(state)

                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { on in
                        if on {
                            mcpService.enablePlugin(plugin.id)
                            Task { await mcpService.ensureServersRunning() }
                        } else {
                            mcpService.disablePlugin(plugin.id)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!hasNpx || needsKey)
            }

            // API key field
            if let keyLabel = plugin.requiresApiKey {
                HStack(spacing: 8) {
                    Image(systemName: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(keyLabel, text: Binding(
                        get: { mcpService.apiKeys[plugin.id] ?? "" },
                        set: { mcpService.setApiKey($0, for: plugin.id) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.caption)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 40)
            }

            // Error display
            if case .error(let msg) = state {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Status badge

    @ViewBuilder
    private func statusBadge(_ state: MCPService.PluginState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .starting:
            ProgressView()
                .controlSize(.mini)
        case .ready(let count):
            Text("\(count) tools")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15), in: Capsule())
                .foregroundStyle(.green)
        case .error:
            EmptyView()
        }
    }
}
