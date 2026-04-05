import SwiftUI

// MARK: - Model selector pill (toolbar)

struct BrainModelButton: View {
    @Environment(MLXService.self) private var mlxService
    @State private var showPicker = false

    var body: some View {
        Button { showPicker.toggle() } label: {
            Label("Models", systemImage: "brain")
                .labelStyle(.iconOnly)
                .foregroundStyle(brainColor)
                .symbolEffect(.pulse, options: .repeating, isActive: mlxService.isLoading)
        }
        .help(helpText)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ModelPickerView { showPicker = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showModelPicker)) { _ in
            showPicker = true
        }
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
            return "Loading model…"
        } else {
            return "Choose a model"
        }
    }
}

// MARK: - Unified model picker (popover)

struct ModelPickerView: View {
    @Environment(MLXService.self) private var mlxService
    @Environment(ModelManager.self) private var modelManager

    var onDismiss: () -> Void

    enum Tab: String, CaseIterable {
        case downloaded = "Downloaded"
        case available = "Available"
    }

    @State private var selectedTab: Tab = .downloaded
    @State private var remoteModels: [HFModelInfo] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var expandedFamily: String?

    private var memoryGB: Double { DeviceCapability.unifiedMemoryGB }
    private var downloadedModels: [ModelManager.DownloadedModel] { modelManager.mlxModels }

    private var filteredLocalModels: [ModelManager.DownloadedModel] {
        guard !searchText.isEmpty else { return downloadedModels }
        let query = searchText.lowercased()
        return downloadedModels.filter { $0.displayName.lowercased().contains(query) }
    }

    /// Group downloaded models by model line (Gemma, Qwen, etc.)
    private var localLineGroups: [(line: String, models: [ModelManager.DownloadedModel])] {
        var order: [String] = []
        var map: [String: [ModelManager.DownloadedModel]] = [:]
        for model in filteredLocalModels {
            let line = modelLineName(model.displayName)
            if map[line] == nil { order.append(line) }
            map[line, default: []].append(model)
        }
        return order.compactMap { line in
            guard let models = map[line] else { return nil }
            return (line: line, models: models)
        }
    }

    private var families: [ModelFamily] {
        let grouped = HFModelInfo.groupByFamily(remoteModels)
        return grouped.filter { family in
            family.variants.contains { !modelManager.isDownloaded($0.id) }
        }
    }

    private var lineGroups: [ModelLineGroup] {
        ModelLineGroup.from(families)
    }

    /// Extract model line name: "gemma-4-31b-it-4bit" → "Gemma"
    private func modelLineName(_ displayName: String) -> String {
        let first = displayName.components(separatedBy: CharacterSet(charactersIn: "-_")).first ?? displayName
        let stripped = first.replacingOccurrences(of: #"\d+\.?\d*$"#, with: "", options: .regularExpression)
        let base = stripped.isEmpty ? first : stripped
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Models")
                        .font(.headline)
                    Text("\(Int(memoryGB)) GB unified memory")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Tabs
            Picker(selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Search bar (available tab only)
            if selectedTab == .available {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search models…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // Active download banner
            if case .downloading(let progress) = mlxService.loadState,
               let modelId = mlxService.activeModelId {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(modelId.components(separatedBy: "/").last ?? modelId)
                                .font(.subheadline.weight(.medium))
                            Text("Downloading… \(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") {
                            mlxService.cancelLoading()
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                    }
                    ProgressView(value: progress)
                        .tint(.accentColor)
                }
                .padding(12)
                .background(.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else if case .loading = mlxService.loadState,
                      let modelId = mlxService.activeModelId {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(modelId.components(separatedBy: "/").last ?? modelId)
                        .font(.subheadline.weight(.medium))
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            Divider()

            // Content
            switch selectedTab {
            case .downloaded:
                downloadedTab
            case .available:
                availableTab
            }
        }
        .frame(width: 420, height: 520)
        .task {
            if downloadedModels.isEmpty { selectedTab = .available }
            await loadRemote()
        }
        .onChange(of: searchText) { debouncedSearch() }
    }

    // MARK: - Downloaded tab

    private var downloadedTab: some View {
        ScrollView {
            if filteredLocalModels.isEmpty {
                ContentUnavailableView(
                    "No Downloaded Models",
                    systemImage: "arrow.down.circle",
                    description: Text("Models you download will appear here.")
                )
                .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(localLineGroups, id: \.line) { group in
                        lineGroupHeader(group.line)
                        ForEach(group.models) { model in
                            downloadedRow(model)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Available tab

    private var availableTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isLoading && lineGroups.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text("Loading…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }

                ForEach(lineGroups) { group in
                    lineGroupHeader(group.name)
                    ForEach(group.families) { family in
                        familyRow(family)
                    }
                }

                if lineGroups.isEmpty && !isLoading {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Model line group header (e.g. "Gemma", "Qwen")

    private func lineGroupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    // MARK: - Downloaded model row

    @ViewBuilder
    private func downloadedRow(_ model: ModelManager.DownloadedModel) -> some View {
        let active = mlxService.activeModelId == model.id && mlxService.isReady
        let loading = mlxService.isLoading && mlxService.activeModelId == model.id
        let incompatible = mlxService.isIncompatible(model.id)
        let failedJustNow = mlxService.activeModelId == model.id && {
            if case .error = mlxService.loadState { return true }
            return false
        }()

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.body)
                            .fontWeight(active ? .semibold : .regular)
                            .foregroundStyle(incompatible && !active ? .secondary : .primary)
                        if incompatible && !failedJustNow {
                            Text("Incompatible")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(model.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if loading {
                    loadingIndicator
                } else if active {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.body)
                } else {
                    Button(failedJustNow ? "Retry" : "Load") {
                        Task {
                            do {
                                try await mlxService.loadModel(id: model.id)
                                onDismiss()
                            } catch {
                                // Stay in picker — error shows below
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Show error inline for just-failed model
            if failedJustNow, case .error(let msg) = mlxService.loadState {
                HStack {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Spacer()
                    Button("Delete") {
                        try? modelManager.deleteModel(model)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Delete", role: .destructive) {
                try? modelManager.deleteModel(model)
            }
        }
    }

    // MARK: - Family row (collapsed + expanded)

    @ViewBuilder
    private func familyRow(_ family: ModelFamily) -> some View {
        let isExpanded = expandedFamily == family.id
        let recommended = family.recommended(memoryGB: memoryGB)
        let anyFits = family.variants.contains { $0.fitsInMemory(memoryGB) }

        VStack(alignment: .leading, spacing: 0) {
            // Family header — tap to expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedFamily = isExpanded ? nil : family.id
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(family.displayName)
                                .font(.body)
                                .foregroundStyle(anyFits ? .primary : .secondary)
                            if !anyFits {
                                Text("Too large")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        HStack(spacing: 8) {
                            if let size = family.parameterSize {
                                Text(size)
                            }
                            if let rec = recommended?.quantLabel {
                                Text(rec + " rec.")
                                    .foregroundStyle(.green)
                            }
                            Text("\(family.variants.count) variants")
                            if family.bestDownloads > 0 {
                                Text("\(formatCount(family.bestDownloads)) ↓")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            // Expanded variant list
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(family.variants, id: \.id) { variant in
                        if !modelManager.isDownloaded(variant.id) {
                            variantRow(variant, isRecommended: variant.id == recommended?.id)
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Variant row (inside expanded family)

    @ViewBuilder
    private func variantRow(_ model: HFModelInfo, isRecommended: Bool) -> some View {
        let active = mlxService.activeModelId == model.id && mlxService.isReady
        let loading = mlxService.isLoading && mlxService.activeModelId == model.id
        let fits = model.fitsInMemory(memoryGB)

        HStack(spacing: 10) {
            if isRecommended {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }

            Text(model.quantLabel ?? model.displayName)
                .font(.body)
                .foregroundStyle(fits ? .primary : .secondary)

            if let size = model.parameterSize {
                Text(size)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            if !fits {
                Text("Too large")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if loading {
                loadingIndicator
            } else if active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body)
            } else if fits {
                Button("Get") {
                    Task {
                        do {
                            try await mlxService.loadModel(id: model.id)
                            await modelManager.scanDownloadedModels()
                            withAnimation { selectedTab = .downloaded }
                        } catch {
                            // Download failed or model unsupported — still rescan
                            // in case partial download landed
                            await modelManager.scanDownloadedModels()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.accentColor)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Loading indicator

    @ViewBuilder
    private var loadingIndicator: some View {
        switch mlxService.loadState {
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: progress).frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        default:
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func debouncedSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)

        // Clear search → reload defaults immediately
        if query.isEmpty {
            Task { await loadRemote() }
            return
        }

        // Wait for user to stop typing before hitting API
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await loadRemote()
        }
    }

    private func loadRemote() async {
        isLoading = true
        defer { isLoading = false }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        // Don't search for very short strings — too broad, wastes API calls
        let search: String? = query.count >= 2 ? query : nil
        do {
            remoteModels = try await modelManager.fetchAvailableModels(
                search: search
            )
        } catch {
            if !Task.isCancelled { remoteModels = [] }
        }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
