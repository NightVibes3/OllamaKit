import SwiftUI
import SwiftData
import UIKit

struct ModelsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadedModel.downloadDate, order: .reverse) private var downloadedModels: [DownloadedModel]
    
    @StateObject private var viewModel = ModelsViewModel()
    @State private var showingSearch = false
    
    var body: some View {
        ZStack {
            AnimatedMeshBackground()
            
            List {
                // Downloaded Models Section
                Section {
                    if downloadedModels.isEmpty {
                        EmptyModelsView()
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(downloadedModels) { model in
                            DownloadedModelRow(model: model, viewModel: viewModel)
                        }
                        .onDelete(perform: deleteModels)
                    }
                } header: {
                    HStack {
                        Text("Downloaded Models")
                        Spacer()
                        Text("\(downloadedModels.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                
                // Browse More Section
                Section {
                    BrowseMoreCard {
                        showingSearch = true
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Models")
        .sheet(isPresented: $showingSearch) {
            ModelSearchSheet()
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
            Spacer()
            
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
            
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                                    Task {
                                        await viewModel.downloadFile(file, modelId: model.modelId)
                                    }
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

        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: systemInfo.machine)) { charPointer in
                String(cString: charPointer)
            }
        }
    }
}

#Preview {
    ModelsView()
        .modelContainer(for: [DownloadedModel.self], inMemory: true)
}
