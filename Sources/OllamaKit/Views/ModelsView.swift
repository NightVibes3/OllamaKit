import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct ModelsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadedModel.downloadDate, order: .reverse) private var downloadedModels: [DownloadedModel]
    
    @ObservedObject private var modelRunner = ModelRunner.shared
    @StateObject private var viewModel = ModelsViewModel()
    @State private var showingSearch = false
    @State private var showingImporter = false

    private var activeModel: DownloadedModel? {
        guard let loadedModelPath = modelRunner.activeLoadedModelPath else { return nil }
        return downloadedModels.first { $0.localPath == loadedModelPath }
    }

    private var supportedImportTypes: [UTType] {
        if let ggufType = UTType(filenameExtension: "gguf") {
            return [ggufType, .data]
        }

        return [.data]
    }
    
    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            ScrollView {
                VStack(spacing: 20) {
                    if let activeModel {
                        SurfaceSectionCard(title: "Active Model") {
                            ActiveModelSummary(model: activeModel)
                        }
                    }

                    BuiltInAppleModelCard()

                    SurfaceSectionCard(
                        title: "Downloaded Models",
                        footer: downloadedModels.isEmpty
                            ? "Download GGUF models from Hugging Face or import a local GGUF file to get started."
                            : "\(downloadedModels.count) model\(downloadedModels.count == 1 ? "" : "s") available on this device."
                    ) {
                        if downloadedModels.isEmpty {
                            EmptyModelsView()
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(downloadedModels.enumerated()), id: \.element.id) { index, model in
                                    DownloadedModelRow(model: model, viewModel: viewModel)

                                    if index < downloadedModels.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }

                    BrowseMoreCard {
                        showingSearch = true
                    }

                    ImportLocalModelCard {
                        showingImporter = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Models")
        .sheet(isPresented: $showingSearch) {
            ModelSearchSheet()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: supportedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await viewModel.importLocalModel(from: url)
                }
            case .failure(let error):
                viewModel.alertTitle = "Import Failed"
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
        .alert(isPresented: $viewModel.showError) {
            Alert(
                title: Text(viewModel.alertTitle),
                message: Text(viewModel.errorMessage),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    private func deleteModels(at offsets: IndexSet) {
        let modelsToDelete = offsets.compactMap { index in
            downloadedModels.indices.contains(index) ? downloadedModels[index] : nil
        }

        for model in modelsToDelete {
            
            // Delete file
            try? FileManager.default.removeItem(atPath: model.localPath)

            if ModelRunner.shared.loadedModelPath == model.localPath {
                ModelRunner.shared.unloadModel()
            }
            if model.matchesStoredReference(AppSettings.shared.defaultModelId) {
                AppSettings.shared.defaultModelId = ""
            }
            
            // Delete from database
            modelContext.delete(model)
        }
        try? modelContext.save()
        Task { @MainActor in
            HapticManager.notification(.warning)
        }
    }
}

struct ActiveModelSummary: View {
    let model: DownloadedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.16))
                        .frame(width: 46, height: 46)

                    Image(systemName: "bolt.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.system(size: 18, weight: .semibold))

                    Text("Loaded and ready for chat")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Unload") {
                    ModelRunner.shared.unloadModel()
                    Task { @MainActor in
                        HapticManager.impact(.medium)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            HStack(spacing: 10) {
                ModelFactChip(icon: "cpu", text: model.quantization)
                ModelFactChip(icon: "externaldrive", text: model.formattedSize)
                ModelFactChip(icon: "text.alignleft", text: "\(model.runtimeContextLength) ctx")
            }
        }
        .padding(.vertical, 16)
    }
}

struct ModelFactChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
    }
}

struct DownloadedModelRow: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var modelRunner = ModelRunner.shared
    @ObservedObject private var settings = AppSettings.shared
    let model: DownloadedModel
    @ObservedObject var viewModel: ModelsViewModel
    @State private var showingOptions = false
    
    var body: some View {
        HStack(spacing: 16) {
            // Model icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .frame(width: 56, height: 56)
                
                Image(systemName: "cube.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(model.displayName)
                    .font(.system(size: 17, weight: .semibold))
                
                HStack(spacing: 12) {
                    if model.modelId.hasPrefix("local/") {
                        Label("Local", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Label(model.quantization, systemImage: "cpu")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .foregroundStyle(.tertiary)
                    
                    Label(model.formattedSize, systemImage: "externaldrive")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 12) {
                    Label("\(max(settings.defaultContextLength, 512)) ctx", systemImage: "text.alignleft")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    
                    if model.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                    }
                }
            }
            
            Spacer()
            
            // Status indicator
            if modelRunner.activeLoadedModelPath == model.localPath {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 22))
            }
            
            Button {
                showingOptions = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button {
                Task {
                    // Validate path before attempting to load
                    guard !model.localPath.isEmpty else {
                        viewModel.errorMessage = "Invalid model path. Please re-download the model."
                        viewModel.showError = true
                        return
                    }
                    
                    guard FileManager.default.fileExists(atPath: model.localPath) else {
                        viewModel.errorMessage = "Model file not found. The app may have been moved or the model needs to be re-downloaded."
                        viewModel.showError = true
                        return
                    }
                    
                    do {
                        try await ModelRunner.shared.loadModel(
                            from: model.localPath,
                            contextLength: model.runtimeContextLength,
                            gpuLayers: AppSettings.shared.gpuLayers
                        )
                        await MainActor.run {
                            HapticManager.notification(.success)
                        }
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                        viewModel.showError = true
                        await MainActor.run {
                            HapticManager.notification(.error)
                        }
                    }
                }
            } label: {
                Label("Load Model", systemImage: "play.circle")
            }
            
            Button {
                model.isFavorite.toggle()
                try? modelContext.save()
                Task { @MainActor in
                    HapticManager.selectionChanged()
                }
            } label: {
                Label(model.isFavorite ? "Unfavorite" : "Favorite", systemImage: model.isFavorite ? "star.slash" : "star")
            }
            
            Button(role: .destructive) {
                deleteModel()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Model Options", isPresented: $showingOptions, titleVisibility: .visible) {
            Button("Load Model") {
                Task {
                    // Validate path before attempting to load
                    guard !model.localPath.isEmpty else {
                        viewModel.errorMessage = "Invalid model path. Please re-download the model."
                        viewModel.showError = true
                        return
                    }
                    
                    guard FileManager.default.fileExists(atPath: model.localPath) else {
                        viewModel.errorMessage = "Model file not found. The app may have been moved or the model needs to be re-downloaded."
                        viewModel.showError = true
                        return
                    }
                    
                    do {
                        try await ModelRunner.shared.loadModel(
                            from: model.localPath,
                            contextLength: model.runtimeContextLength,
                            gpuLayers: AppSettings.shared.gpuLayers
                        )
                        await MainActor.run {
                            HapticManager.notification(.success)
                        }
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                        viewModel.showError = true
                        await MainActor.run {
                            HapticManager.notification(.error)
                        }
                    }
                }
            }
            
            Button("Set as Default") {
                AppSettings.shared.defaultModelId = model.persistentReference
                viewModel.alertTitle = "Default Model"
                viewModel.errorMessage = "\(model.displayName) will be preselected for new chats."
                viewModel.showError = true
                Task { @MainActor in
                    HapticManager.selectionChanged()
                }
            }
            
            Button("View Info") {
                viewModel.alertTitle = "Model Info"
                viewModel.errorMessage = "Model: \(model.displayName)\nQuantization: \(model.quantization)\nContext: \(model.runtimeContextLength)\nPath: \(model.localPath)"
                viewModel.showError = true
            }
            
            Button("Delete", role: .destructive) {
                deleteModel()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func deleteModel() {
        if !model.localPath.isEmpty {
            try? FileManager.default.removeItem(atPath: model.localPath)
        }
        if ModelRunner.shared.loadedModelPath == model.localPath {
            ModelRunner.shared.unloadModel()
        }
        if model.matchesStoredReference(AppSettings.shared.defaultModelId) {
            AppSettings.shared.defaultModelId = ""
        }
        modelContext.delete(model)
        try? modelContext.save()
        Task { @MainActor in
            HapticManager.notification(.warning)
        }
    }
}

struct EmptyModelsView: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 80, height: 80)
                
                Image(systemName: "cube.box")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
            
            Text("No Models Yet")
                .font(.system(size: 20, weight: .bold))
            
            Text("Download GGUF models from Hugging Face to get started")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.vertical, 18)
    }
}

struct BuiltInAppleModelCard: View {
    @ObservedObject private var settings = AppSettings.shared

    private var model: DownloadedModel {
        BuiltInModelCatalog.appleOnDeviceModel()
    }

    private var availability: BuiltInModelAvailability {
        BuiltInModelCatalog.availability()
    }

    private var isDefault: Bool {
        model.matchesStoredReference(settings.defaultModelId)
    }

    var body: some View {
        SurfaceSectionCard(
            title: "Apple On-Device AI",
            footer: availability.detail
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(availability.tint.opacity(0.16))
                            .frame(width: 46, height: 46)

                        Image(systemName: "apple.logo")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(availability.tint)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayName)
                            .font(.system(size: 18, weight: .semibold))

                        Text("Built into iOS through Apple's Foundation Models framework")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(availability.title)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(availability.tint.opacity(0.18))
                        )
                        .foregroundStyle(availability.tint)
                }

                HStack(spacing: 10) {
                    ModelFactChip(icon: "apple.logo", text: "Built In")
                    ModelFactChip(icon: "bolt.fill", text: "On Device")
                    ModelFactChip(icon: "sparkles", text: "Apple AI")
                }

                HStack(spacing: 12) {
                    Button(isDefault ? "Default for New Chats" : "Set as Default") {
                        AppSettings.shared.defaultModelId = model.persistentReference
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!availability.isAvailable || isDefault)

                    if isDefault {
                        Button("Clear Default") {
                            AppSettings.shared.defaultModelId = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }
}

struct BrowseMoreCard: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [.purple.opacity(0.3), .blue.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Browse Hugging Face")
                        .font(.system(size: 17, weight: .semibold))
                    
                    Text("Find and download GGUF models")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct ImportLocalModelCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [.green.opacity(0.28), .cyan.opacity(0.24)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)

                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Local GGUF")
                        .font(.system(size: 17, weight: .semibold))

                    Text("Bring an existing model file into the app")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct ModelSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var searchVM = ModelSearchViewModel()
    @State private var searchText = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()
                
                List {
                    if searchVM.isSearching {
                        Section {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(1.2)
                                Spacer()
                            }
                            .padding(.vertical, 40)
                            .listRowBackground(Color.clear)
                        }
                    } else if searchText.isEmpty {
                        Section {
                            DeviceCapabilityCard(profile: searchVM.deviceProfile)
                                .listRowBackground(Color.clear)
                        } header: {
                            Text("This Device")
                        }

                        Section {
                            if searchVM.isLoadingRecommendations {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                                .padding(.vertical, 24)
                                .listRowBackground(Color.clear)
                            } else if searchVM.recommendations.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 42))
                                        .foregroundStyle(.secondary)

                                    Text("No tailored suggestions yet")
                                        .font(.system(size: 19, weight: .bold))

                                    Text("Search any GGUF model below. Compatibility badges in model details will still tell you what is realistic for this phone.")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, minHeight: 180)
                                .padding(.vertical, 20)
                                .listRowBackground(Color.clear)
                            } else {
                                ForEach(searchVM.recommendations) { recommendation in
                                    RecommendedModelRow(recommendation: recommendation, viewModel: searchVM)
                                }
                            }
                        } header: {
                            Text("Recommended Downloads")
                        } footer: {
                            Text("These are suggestions based on this phone's RAM budget. You can still search for and download any model.")
                        }
                    } else if searchVM.results.isEmpty {
                        Section {
                            VStack(spacing: 12) {
                                Spacer()
                                
                                Image(systemName: "magnifyingglass.circle")
                                    .font(.system(size: 50))
                                    .foregroundStyle(.secondary)
                                
                                Text("No Results")
                                    .font(.system(size: 20, weight: .bold))
                                
                                Text("Try a different search term")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .listRowBackground(Color.clear)
                        }
                    } else {
                        Section {
                            ForEach(searchVM.results) { model in
                                SearchResultRow(model: model, viewModel: searchVM)
                            }
                        } header: {
                            Text("Search Results")
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                        )
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Find Models")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models (e.g., llama, mistral)")
            .onSubmit(of: .search) {
                Task {
                    await searchVM.search(query: searchText)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(searchVM.isDownloading)
                }
            }
            .task {
                await searchVM.loadRecommendationsIfNeeded()
            }
            .alert("Download Failed", isPresented: Binding(
                get: { searchVM.downloadError != nil },
                set: { if !$0 { searchVM.downloadError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(searchVM.downloadError ?? "")
            }
            .sheet(item: $searchVM.selectedModel) { model in
                ModelDetailSheet(model: model, viewModel: searchVM)
            }
        }
        .interactiveDismissDisabled(searchVM.isDownloading)
    }
}

struct SearchResultRow: View {
    let model: HuggingFaceModel
    @ObservedObject var viewModel: ModelSearchViewModel
    
    var body: some View {
        Button {
            viewModel.selectedModel = model
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: "cube")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    
                    Text(model.organization)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 12) {
                        if let downloads = model.downloads {
                            Label(formatNumber(downloads), systemImage: "arrow.down.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        
                        if let likes = model.likes {
                            Label(formatNumber(likes), systemImage: "heart")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .disabled(viewModel.isDownloading)
    }
    
    func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000)
        } else if num >= 1_000 {
            return String(format: "%.1fk", Double(num) / 1_000)
        }
        return "\(num)"
    }
}

struct ModelDetailSheet: View {
    let model: HuggingFaceModel
    @ObservedObject var viewModel: ModelSearchViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()
                
                List {
                    // Model Info
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.displayName)
                                .font(.system(size: 24, weight: .bold))
                            
                            Text(model.organization)
                                .font(.system(size: 17))
                                .foregroundStyle(.secondary)
                            
                            if let description = model.description {
                                Text(description)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            }
                            
                            HStack(spacing: 16) {
                                if let downloads = model.downloads {
                                    StatBadge(value: formatNumber(downloads), label: "Downloads", icon: "arrow.down")
                                }
                                
                                if let likes = model.likes {
                                    StatBadge(value: formatNumber(likes), label: "Likes", icon: "heart")
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                    
                    // GGUF Files
                    Section {
                        if viewModel.isLoadingFiles {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 20)
                        } else if viewModel.availableFiles.isEmpty {
                            Text("No GGUF files found")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(viewModel.availableFiles) { file in
                                GGUFFileRow(
                                    file: file,
                                    compatibility: viewModel.deviceProfile.compatibility(for: file.size),
                                    viewModel: viewModel
                                ) {
                                    viewModel.requestDownload(file, modelId: model.modelId)
                                }
                            }
                        }
                    } header: {
                        Text("Available Files")
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.ultraThinMaterial)
                    )
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Model Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(viewModel.isDownloading)
                }
            }
            .task {
                await viewModel.loadFiles(for: model.modelId)
            }
            .alert(item: $viewModel.pendingDownloadWarning) { warning in
                Alert(
                    title: Text(warning.title),
                    message: Text(warning.message),
                    primaryButton: .default(Text("Download Anyway")) {
                        viewModel.confirmPendingDownload()
                    },
                    secondaryButton: .cancel {
                        viewModel.cancelPendingDownload()
                    }
                )
            }
        }
        .interactiveDismissDisabled(viewModel.isDownloading)
    }
    
    func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000)
        } else if num >= 1_000 {
            return String(format: "%.1fk", Double(num) / 1_000)
        }
        return "\(num)"
    }
}

struct StatBadge: View {
    let value: String
    let label: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
            
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
    }
}

struct GGUFFileRow: View {
    let file: GGUFInfo
    let compatibility: ModelFileCompatibility
    @ObservedObject var viewModel: ModelSearchViewModel
    let downloadAction: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    if let quant = file.quantization {
                        Label(quant, systemImage: "cpu")
                            .font(.system(size: 12))
                    }
                    
                    if let size = file.size {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 12))
                    }

                    CompatibilityBadge(compatibility: compatibility)
                }
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingFile?.url == file.url {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(viewModel.downloadProgress)%")
                            .font(.system(size: 12, weight: .medium))
                        
                        ProgressView(value: Double(viewModel.downloadProgress) / 100.0)
                            .frame(width: 60)
                    }

                    Button {
                        viewModel.cancelCurrentDownload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button(action: downloadAction) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
class ModelsViewModel: ObservableObject {
    @Published var showError = false
    @Published var alertTitle = "Error"
    @Published var errorMessage = ""

    func importLocalModel(from sourceURL: URL) async {
        do {
            let importedModel = try importGGUFModel(from: sourceURL)
            ModelStorage.shared.upsertDownloadedModel(importedModel)
            alertTitle = "Model Imported"
            errorMessage = "\(importedModel.displayName) is ready to load."
            showError = true
            HapticManager.notification(.success)
        } catch {
            alertTitle = "Import Failed"
            errorMessage = error.localizedDescription
            showError = true
            HapticManager.notification(.error)
        }
    }

    private func importGGUFModel(from sourceURL: URL) throws -> DownloadedModel {
        guard sourceURL.pathExtension.lowercased() == "gguf" else {
            throw LocalModelImportError.invalidFileType
        }

        let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LocalModelImportError.fileMissing
        }

        try ModelPathHelper.ensureModelsDirectoryExists()

        let importsDirectory = ModelPathHelper.modelsDirectoryURL.appendingPathComponent("LocalImports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)

        let destinationURL = uniqueImportedDestinationURL(for: sourceURL.lastPathComponent, in: importsDirectory)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let size = (try FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let filename = destinationURL.deletingPathExtension().lastPathComponent

        return DownloadedModel(
            name: filename,
            modelId: "local/\(sanitizedLocalModelIdentifier(for: filename))",
            localPath: destinationURL.path,
            size: size,
            downloadDate: .now,
            isDownloaded: true,
            quantization: detectQuantization(from: destinationURL.lastPathComponent) ?? "GGUF",
            parameters: detectParameterSize(from: destinationURL.lastPathComponent),
            contextLength: AppSettings.shared.defaultContextLength
        )
    }

    private func uniqueImportedDestinationURL(for filename: String, in directory: URL) -> URL {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        let baseName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent

        var candidate = directory.appendingPathComponent(filename)
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = "\(baseName)-\(suffix).\(fileExtension)"
            candidate = directory.appendingPathComponent(nextName)
            suffix += 1
        }

        return candidate
    }

    private func sanitizedLocalModelIdentifier(for name: String) -> String {
        let lowered = name.lowercased()
        let sanitized = lowered.replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
        return sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func detectQuantization(from filename: String) -> String? {
        let patterns = [
            "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L",
            "Q4_0", "Q4_K_S", "Q4_K_M",
            "Q5_0", "Q5_K_S", "Q5_K_M",
            "Q6_K", "Q8_0", "F16", "FP16", "FP32"
        ]

        return patterns.first { filename.localizedCaseInsensitiveContains($0) }
    }

    private func detectParameterSize(from filename: String) -> String {
        let matches = filename.range(of: #"\d+(\.\d+)?[Bb]"#, options: .regularExpression)
        return matches.map { String(filename[$0]).uppercased() } ?? "Unknown"
    }
}

enum LocalModelImportError: LocalizedError {
    case invalidFileType
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .invalidFileType:
            return "Please choose a GGUF model file."
        case .fileMissing:
            return "The selected file is no longer available."
        }
    }
}

@MainActor
class ModelSearchViewModel: ObservableObject {
    @Published private(set) var deviceProfile = DeviceCapabilityInspector.current()
    @Published var results: [HuggingFaceModel] = []
    @Published var isSearching = false
    @Published var selectedModel: HuggingFaceModel?
    
    @Published var availableFiles: [GGUFInfo] = []
    @Published var isLoadingFiles = false

    @Published var recommendations: [ModelRecommendation] = []
    @Published var isLoadingRecommendations = false
    
    @Published var isDownloading = false
    @Published var downloadingFile: GGUFInfo?
    @Published var downloadProgress = 0
    @Published var downloadError: String?
    @Published var pendingDownloadWarning: ModelDownloadWarning?

    private var searchRequestID = UUID()
    private var filesRequestID = UUID()
    private var recommendationsRequestID = UUID()
    
    func search(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID()
        searchRequestID = requestID

        guard !trimmedQuery.isEmpty else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        
        do {
            let fetchedResults = try await HuggingFaceService.shared.searchModels(query: trimmedQuery)
            guard searchRequestID == requestID else { return }
            results = fetchedResults
        } catch {
            guard searchRequestID == requestID else { return }
            results = []
        }

        guard searchRequestID == requestID else { return }
        isSearching = false
    }
    
    func loadFiles(for modelId: String) async {
        let requestID = UUID()
        filesRequestID = requestID
        availableFiles = []
        isLoadingFiles = true
        
        do {
            let files = try await HuggingFaceService.shared.getModelFiles(modelId: modelId)
            guard filesRequestID == requestID else { return }
            availableFiles = files
        } catch {
            guard filesRequestID == requestID else { return }
            availableFiles = []
        }

        guard filesRequestID == requestID else { return }
        isLoadingFiles = false
    }

    func loadRecommendationsIfNeeded() async {
        guard recommendations.isEmpty, !isLoadingRecommendations else { return }

        let requestID = UUID()
        recommendationsRequestID = requestID
        isLoadingRecommendations = true
        defer {
            if recommendationsRequestID == requestID {
                isLoadingRecommendations = false
            }
        }

        do {
            let trendingModels = try await HuggingFaceService.shared.getTrendingModels(limit: 18)
            guard recommendationsRequestID == requestID else { return }

            var suggestedModels: [ModelRecommendation] = []

            for model in trendingModels {
                guard recommendationsRequestID == requestID else { return }

                let files = try await HuggingFaceService.shared.getModelFiles(modelId: model.modelId)
                guard let bestFile = bestRecommendedFile(from: files) else { continue }

                let compatibility = deviceProfile.compatibility(for: bestFile.size)
                guard compatibility != .tooLarge else { continue }

                suggestedModels.append(
                    ModelRecommendation(model: model, suggestedFile: bestFile, compatibility: compatibility)
                )

                if suggestedModels.count == 6 {
                    break
                }
            }

            guard recommendationsRequestID == requestID else { return }
            recommendations = suggestedModels
        } catch {
            guard recommendationsRequestID == requestID else { return }
            recommendations = []
        }
    }
    
    func downloadFile(_ file: GGUFInfo, modelId: String) async {
        downloadError = nil
        isDownloading = true
        downloadingFile = file
        downloadProgress = 0

        defer {
            isDownloading = false
            downloadingFile = nil
        }

        do {
            let model = try await HuggingFaceService.shared.downloadModel(
                from: file.url,
                filename: file.filename,
                modelId: modelId
            ) { progress in
                Task { @MainActor in
                    self.downloadProgress = progress.percentage
                }
            }

            ModelStorage.shared.upsertDownloadedModel(model)
            downloadProgress = 100
            HapticManager.notification(.success)
        } catch {
            if isCancellationError(error) {
                downloadProgress = 0
                HapticManager.impact(.medium)
                return
            }

            downloadError = error.localizedDescription
            HapticManager.notification(.error)
        }
    }

    func requestDownload(_ file: GGUFInfo, modelId: String) {
        let compatibility = deviceProfile.compatibility(for: file.size)

        switch compatibility {
        case .recommended, .unknown:
            Task {
                await downloadFile(file, modelId: modelId)
            }
        case .supported, .tooLarge:
            pendingDownloadWarning = ModelDownloadWarning(
                file: file,
                modelId: modelId,
                compatibility: compatibility,
                profile: deviceProfile
            )
        }
    }

    func confirmPendingDownload() {
        guard let pendingDownloadWarning else { return }
        self.pendingDownloadWarning = nil

        Task {
            await downloadFile(pendingDownloadWarning.file, modelId: pendingDownloadWarning.modelId)
        }
    }

    func cancelPendingDownload() {
        pendingDownloadWarning = nil
    }

    func cancelCurrentDownload() {
        guard let downloadingFile else { return }
        HuggingFaceService.shared.cancelDownload(id: downloadingFile.id)
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func bestRecommendedFile(from files: [GGUFInfo]) -> GGUFInfo? {
        files
            .compactMap { file -> (ModelFileCompatibility, Int, Int64, GGUFInfo)? in
                let compatibility = deviceProfile.compatibility(for: file.size)
                guard compatibility != .tooLarge else { return nil }
                return (
                    compatibility,
                    quantizationRank(for: file.quantization),
                    file.size ?? .max,
                    file
                )
            }
            .sorted { lhs, rhs in
                if lhs.0.sortRank != rhs.0.sortRank {
                    return lhs.0.sortRank < rhs.0.sortRank
                }

                if lhs.1 != rhs.1 {
                    return lhs.1 < rhs.1
                }

                return lhs.2 < rhs.2
            }
            .first?
            .3
    }

    private func quantizationRank(for quantization: String?) -> Int {
        switch quantization?.uppercased() {
        case "Q4_K_M", "Q4_K_S", "Q4_0":
            return 0
        case "Q5_K_M", "Q5_K_S", "Q5_0", "Q6_K":
            return 1
        case "Q3_K_M", "Q3_K_S", "Q3_K_L", "Q2_K":
            return 2
        case "Q8_0", "F16", "FP16", "FP32":
            return 3
        default:
            return 4
        }
    }
}

struct DeviceCapabilityCard: View {
    let profile: DeviceCapabilityProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.deviceLabel)
                        .font(.system(size: 18, weight: .semibold))

                    Text("\(profile.formattedPhysicalMemory) RAM • iOS \(profile.systemVersion)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "iphone.gen3")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }

            Text("Best results on this device are usually GGUF files up to \(profile.formattedRecommendedBudget). Files up to \(profile.formattedSupportedBudget) may still run, but larger ones are likely to be slow, unload often, or fail to fit.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct RecommendedModelRow: View {
    let recommendation: ModelRecommendation
    @ObservedObject var viewModel: ModelSearchViewModel

    var body: some View {
        Button {
            viewModel.selectedModel = recommendation.model
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .frame(width: 50, height: 50)

                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(recommendation.model.displayName)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)

                    Text(recommendation.suggestedFile.filename)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let quantization = recommendation.suggestedFile.quantization {
                            Label(quantization, systemImage: "cpu")
                                .font(.system(size: 12))
                        }

                        if let size = recommendation.suggestedFile.size {
                            Text("•")
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.system(size: 12))
                        }

                        CompatibilityBadge(compatibility: recommendation.compatibility)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .disabled(viewModel.isDownloading)
    }
}

struct CompatibilityBadge: View {
    let compatibility: ModelFileCompatibility

    var body: some View {
        Text(compatibility.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(compatibility.tint.opacity(0.18))
            )
            .foregroundStyle(compatibility.tint)
    }
}

struct ModelRecommendation: Identifiable {
    let model: HuggingFaceModel
    let suggestedFile: GGUFInfo
    let compatibility: ModelFileCompatibility

    var id: String {
        "\(model.id)#\(suggestedFile.id)"
    }
}

struct ModelDownloadWarning: Identifiable {
    let file: GGUFInfo
    let modelId: String
    let compatibility: ModelFileCompatibility
    let profile: DeviceCapabilityProfile

    var id: String {
        "\(modelId)#\(file.id)"
    }

    var title: String {
        switch compatibility {
        case .supported:
            return "Large Model Download"
        case .tooLarge:
            return "Model May Not Fit"
        case .recommended, .unknown:
            return "Download Model"
        }
    }

    var message: String {
        let filename = file.filename
        let recommendedBudget = profile.formattedRecommendedBudget
        let supportedBudget = profile.formattedSupportedBudget
        let fileSize = file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"

        switch compatibility {
        case .supported:
            return "\(filename) (\(fileSize)) is larger than the recommended budget for \(profile.deviceLabel). It may still run, but it can be slower and unload more often.\n\nRecommended: up to \(recommendedBudget)\nMay run: up to \(supportedBudget)"
        case .tooLarge:
            return "\(filename) (\(fileSize)) is above the likely working size for \(profile.deviceLabel). You can still download it, but it may fail to load or run poorly.\n\nRecommended: up to \(recommendedBudget)\nMay run: up to \(supportedBudget)"
        case .recommended, .unknown:
            return "Download \(filename)?"
        }
    }
}

enum ModelFileCompatibility {
    case recommended
    case supported
    case tooLarge
    case unknown

    var title: String {
        switch self {
        case .recommended:
            return "Recommended"
        case .supported:
            return "May Run"
        case .tooLarge:
            return "Too Large"
        case .unknown:
            return "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .recommended:
            return .green
        case .supported:
            return .orange
        case .tooLarge:
            return .red
        case .unknown:
            return .secondary
        }
    }

    var sortRank: Int {
        switch self {
        case .recommended:
            return 0
        case .supported:
            return 1
        case .unknown:
            return 2
        case .tooLarge:
            return 3
        }
    }
}

struct DeviceCapabilityProfile {
    let machineIdentifier: String
    let systemVersion: String
    let physicalMemoryBytes: Int64
    let recommendedModelBudgetBytes: Int64
    let supportedModelBudgetBytes: Int64

    var deviceLabel: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
    }

    var formattedPhysicalMemory: String {
        ByteCountFormatter.string(fromByteCount: physicalMemoryBytes, countStyle: .memory)
    }

    var formattedRecommendedBudget: String {
        ByteCountFormatter.string(fromByteCount: recommendedModelBudgetBytes, countStyle: .file)
    }

    var formattedSupportedBudget: String {
        ByteCountFormatter.string(fromByteCount: supportedModelBudgetBytes, countStyle: .file)
    }

    func compatibility(for fileSize: Int64?) -> ModelFileCompatibility {
        guard let fileSize else { return .unknown }

        if fileSize <= recommendedModelBudgetBytes {
            return .recommended
        }

        if fileSize <= supportedModelBudgetBytes {
            return .supported
        }

        return .tooLarge
    }
}

enum DeviceCapabilityInspector {
    static func current() -> DeviceCapabilityProfile {
        let physicalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        let recommendedBudget = max(
            min(Int64(Double(physicalMemory) * 0.30), physicalMemory - 3_000_000_000),
            1_500_000_000
        )
        let supportedBudget = max(
            min(Int64(Double(physicalMemory) * 0.42), physicalMemory - 2_000_000_000),
            recommendedBudget
        )

        return DeviceCapabilityProfile(
            machineIdentifier: machineIdentifier(),
            systemVersion: UIDevice.current.systemVersion,
            physicalMemoryBytes: physicalMemory,
            recommendedModelBudgetBytes: recommendedBudget,
            supportedModelBudgetBytes: supportedBudget
        )
    }

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        var machine = systemInfo.machine
        let capacity = MemoryLayout.size(ofValue: machine)

        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { charPointer in
                String(cString: charPointer)
            }
        }
    }
}

#Preview {
    ModelsView()
        .modelContainer(for: [DownloadedModel.self], inMemory: true)
}
