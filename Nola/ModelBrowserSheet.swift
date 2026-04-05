import SwiftUI

struct ModelBrowserSheet: View {
    @Environment(MLXService.self) private var mlxService
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.dismiss) private var dismiss

    @State private var remoteModels: [HFModelInfo] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var expandedFamily: String?

    private var memoryGB: Double { DeviceCapability.unifiedMemoryGB }

    private var families: [ModelFamily] {
        let grouped = HFModelInfo.groupByFamily(remoteModels)
        return grouped.filter { family in
            family.variants.contains { !modelManager.isDownloaded($0.id) }
        }
    }

    private var lineGroups: [ModelLineGroup] {
        ModelLineGroup.from(families)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browse Models")
                        .font(.headline)
                    Text("\(Int(memoryGB)) GB unified memory")
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

            // Search bar
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
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            // Download progress banner
            if let modelId = mlxService.downloadingModelId {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(modelId.components(separatedBy: "/").last ?? modelId)
                                .font(.subheadline.weight(.medium))
                            Text("Downloading… \(Int(mlxService.downloadingProgress * 100))%")
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
                    ProgressView(value: mlxService.downloadingProgress)
                        .tint(Color.accentColor)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            // Pending model banner
            if let pendingId = mlxService.pendingModelId {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pendingId.components(separatedBy: "/").last ?? pendingId)
                            .font(.subheadline.weight(.medium))
                        Text("Ready to use")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Switch") {
                        mlxService.activatePendingModel()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button {
                        mlxService.dismissPendingModel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            Divider()

            // Model list
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
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 500, idealHeight: 600)
        .task { await loadRemote() }
        .onChange(of: searchText) { debouncedSearch() }
    }

    // MARK: - Line group header

    private func lineGroupHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    // MARK: - Family row

    @ViewBuilder
    private func familyRow(_ family: ModelFamily) -> some View {
        let isExpanded = expandedFamily == family.id
        let recommended = family.recommended(memoryGB: memoryGB)
        let anyFits = family.variants.contains { $0.fitsInMemory(memoryGB) }

        VStack(alignment: .leading, spacing: 0) {
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

    // MARK: - Variant row

    @ViewBuilder
    private func variantRow(_ model: HFModelInfo, isRecommended: Bool) -> some View {
        let active = mlxService.activeModelId == model.id && mlxService.isReady
        let loading = (mlxService.isLoading && mlxService.activeModelId == model.id)
            || mlxService.downloadingModelId == model.id
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
                        } catch {
                            await modelManager.scanDownloadedModels()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.accentColor)
                .disabled(mlxService.isLoading)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Loading indicator

    @ViewBuilder
    private var loadingIndicator: some View {
        if mlxService.isDownloading {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: mlxService.downloadingProgress).frame(width: 60)
                Text("\(Int(mlxService.downloadingProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func debouncedSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)

        if query.isEmpty {
            Task { await loadRemote() }
            return
        }

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
        let search: String? = query.count >= 2 ? query : nil
        do {
            remoteModels = try await modelManager.fetchAvailableModels(search: search)
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
