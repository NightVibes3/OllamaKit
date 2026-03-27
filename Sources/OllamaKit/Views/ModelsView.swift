import SwiftUI
import SwiftData

struct ModelsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadedModel.downloadDate, order: .reverse) private var downloadedModels: [DownloadedModel]
    
    @StateObject private var viewModel = ModelsViewModel()
    @State private var searchText = ""
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
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }
    
    private func deleteModels(at offsets: IndexSet) {
        for index in offsets {
            let model = downloadedModels[index]
            
            // Delete file
            try? FileManager.default.removeItem(atPath: model.localPath)
            
            // Delete from database
            modelContext.delete(model)
        }
        try? modelContext.save()
    }
}

struct DownloadedModelRow: View {
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
                    .foregroundStyle(.accent)
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
                    Label("\(model.contextLength) ctx", systemImage: "text.alignleft")
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
            if ModelRunner.shared.isLoaded && ModelRunner.shared.loadedModelPath == model.localPath {
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
                            contextLength: model.contextLength
                        )
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                        viewModel.showError = true
                    }
                }
            } label: {
                Label("Load Model", systemImage: "play.circle")
            }
            
            Button {
                model.isFavorite.toggle()
            } label: {
                Label(model.isFavorite ? "Unfavorite" : "Favorite", systemImage: model.isFavorite ? "star.slash" : "star")
            }
            
            Button(role: .destructive) {
                // Delete
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
                            contextLength: model.contextLength
                        )
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                        viewModel.showError = true
                    }
                }
            }
            
            Button("Set as Default") {
                // Set as default
            }
            
            Button("View Info") {
                // Show info
            }
            
            Button("Cancel", role: .cancel) {}
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
    @Environment(\.modelContext) private var modelContext
    
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
                            VStack(spacing: 12) {
                                Spacer()
                                
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 50))
                                    .foregroundStyle(.secondary)
                                
                                Text("Search Hugging Face")
                                    .font(.system(size: 20, weight: .bold))
                                
                                Text("Find GGUF models to download and chat with")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .listRowBackground(Color.clear)
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
                }
            }
            .sheet(item: $searchVM.selectedModel) { model in
                ModelDetailSheet(model: model, viewModel: searchVM)
            }
        }
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
                        .foregroundStyle(.accent)
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
    @Environment(\.modelContext) private var modelContext
    
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
                                GGUFFileRow(file: file, viewModel: viewModel)
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
                }
            }
            .task {
                await viewModel.loadFiles(for: model.modelId)
            }
        }
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
    @ObservedObject var viewModel: ModelSearchViewModel
    
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
                }
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingFile?.url == file.url {
                // Show progress
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(viewModel.downloadProgress)%")
                        .font(.system(size: 12, weight: .medium))
                    
                    ProgressView(value: Double(viewModel.downloadProgress) / 100.0)
                        .frame(width: 60)
                }
            } else {
                Button {
                    Task {
                        await viewModel.downloadFile(file)
                    }
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.accent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
class ModelsViewModel: ObservableObject {
    @Published var showError = false
    @Published var errorMessage = ""
}

@MainActor
class ModelSearchViewModel: ObservableObject {
    @Published var results: [HuggingFaceModel] = []
    @Published var isSearching = false
    @Published var selectedModel: HuggingFaceModel?
    
    @Published var availableFiles: [GGUFInfo] = []
    @Published var isLoadingFiles = false
    
    @Published var isDownloading = false
    @Published var downloadingFile: GGUFInfo?
    @Published var downloadProgress = 0
    
    func search(query: String) async {
        isSearching = true
        defer { isSearching = false }
        
        do {
            results = try await HuggingFaceService.shared.searchModels(query: query)
        } catch {
            results = []
        }
    }
    
    func loadFiles(for modelId: String) async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        
        do {
            availableFiles = try await HuggingFaceService.shared.getModelFiles(modelId: modelId)
        } catch {
            availableFiles = []
        }
    }
    
    func downloadFile(_ file: GGUFInfo) async {
        isDownloading = true
        downloadingFile = file
        downloadProgress = 0
        
        // Simulate download progress
        for i in stride(from: 0, to: 100, by: 5) {
            downloadProgress = i
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        isDownloading = false
        downloadingFile = nil
    }
}

#Preview {
    ModelsView()
        .modelContainer(for: [DownloadedModel.self], inMemory: true)
}
