import SwiftUI

// MARK: - Brain button — switch between downloaded models

struct BrainModelButton: View {
    @Environment(MLXService.self) private var mlxService
    @Environment(ModelManager.self) private var modelManager

    @State private var showMenu = false

    var body: some View {
        Button { showMenu = true } label: {
            Label("Models", systemImage: "brain")
                .labelStyle(.iconOnly)
                .foregroundStyle(brainColor)
                .symbolEffect(.pulse, options: .repeating, isActive: mlxService.isLoading)
        }
        .help(helpText)
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            modelList
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            let models = modelManager.mlxModels
            if models.isEmpty {
                Text("No models downloaded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ForEach(models) { model in
                    let isActive = mlxService.activeModelId == model.id && mlxService.isReady
                    let isLoading = mlxService.activeModelId == model.id && mlxService.isLoading
                    Button {
                        if !isActive && !isLoading {
                            Task { try? await mlxService.loadModel(id: model.id) }
                        }
                        if !isLoading { showMenu = false }
                    } label: {
                        HStack(spacing: 10) {
                            if isLoading {
                                ProgressView(value: mlxService.loadingProgress)
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                            } else {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isActive ? Color.green : Color.gray.opacity(0.3))
                                    .font(.body)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .font(.body)
                                    .fontWeight(isActive || isLoading ? .semibold : .regular)
                                Text(isLoading ? "Loading \(Int(mlxService.loadingProgress * 100))%…" : model.formattedSize)
                                    .font(.caption)
                                    .foregroundStyle(isLoading ? Color.accentColor : .secondary)
                            }
                            Spacer()
                            if !isActive && !isLoading {
                                Button {
                                    try? modelManager.deleteModel(model)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }
        }
        .frame(width: 280)
        .padding(.vertical, 8)
    }


    private var brainColor: Color {
        if mlxService.isLoading {
            return .accentColor
        } else if mlxService.isReady {
            return .green
        } else {
            return .secondary
        }
    }

    private var helpText: String {
        if let id = mlxService.activeModelId, mlxService.isReady {
            return id.components(separatedBy: "/").last ?? id
        } else if mlxService.isLoading {
            return "Loading model… \(Int(mlxService.loadingProgress * 100))%"
        } else {
            return "Choose a model"
        }
    }
}

// MARK: - Download button — browse & download from HuggingFace

struct DownloadModelsButton: View {
    @Environment(MLXService.self) private var mlxService
    @State private var showBrowser = false

    var body: some View {
        Button { showBrowser = true } label: {
            Label("Browse Models", systemImage: "arrow.down.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(mlxService.isDownloading ? Color.accentColor : .secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: mlxService.isDownloading)
        }
        .help(mlxService.isDownloading ? "Downloading…" : "Browse & download models")
        .sheet(isPresented: $showBrowser) {
            ModelBrowserSheet()
        }
    }
}

// MARK: - Thinking toggle

struct ThinkingToggleButton: View {
    @Environment(MLXService.self) private var mlxService
    @Environment(ModelManager.self) private var modelManager
    var chatViewModel: ChatViewModel

    private var modelSupportsThinking: Bool {
        guard let id = mlxService.activeModelId else { return false }
        return modelManager.mlxModels.first { $0.id == id }?.supportsThinking ?? false
    }

    var body: some View {
        Button {
            chatViewModel.thinkingEnabled.toggle()
        } label: {
            Label("Thinking", systemImage: "lightbulb")
                .labelStyle(.iconOnly)
                .symbolVariant(chatViewModel.thinkingEnabled ? .fill : .none)
                .foregroundStyle(buttonColor)
        }
        .help(helpText)
        .disabled(!mlxService.isReady || !modelSupportsThinking)
        .onChange(of: mlxService.activeModelId) {
            if !modelSupportsThinking {
                chatViewModel.thinkingEnabled = false
            }
        }
    }

    private var buttonColor: Color {
        if !modelSupportsThinking { return .secondary.opacity(0.4) }
        return chatViewModel.thinkingEnabled ? .accentColor : .secondary
    }

    private var helpText: String {
        if !modelSupportsThinking { return "Thinking not supported by this model" }
        return chatViewModel.thinkingEnabled ? "Thinking: On" : "Thinking: Off"
    }
}
