import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<DownloadedModel> { $0.isDownloaded == true }) private var downloadedModels: [DownloadedModel]
    @Bindable var session: ChatSession
    
    @StateObject private var viewModel = ChatViewModel()
    @State private var messageText = ""
    @State private var showingModelSelector = false
    @State private var showingRenameDialog = false
    @State private var pendingTitle = ""
    
    @Namespace private var bottomID

    private var trimmedMessageText: String {
        messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var downloadedModelRevision: [String] {
        downloadedModels.map { "\($0.id.uuidString)|\($0.modelId)|\($0.localPath)" }
    }
    
    var body: some View {
        ZStack {
            AnimatedMeshBackground()
            
            VStack(spacing: 0) {
                // Messages List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(session.orderedMessages, id: \.id) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            
                            if viewModel.isGenerating {
                                TypingIndicator()
                                    .id("typing")
                            }
                            
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: session.orderedMessages.count) { _ in
                        withAnimation {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.isGenerating) { _ in
                        withAnimation {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.streamRevision) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }
                
                // Input Area
                VStack(spacing: 0) {
                    Divider()
                    
                    HStack(spacing: 12) {
                        // Model selector button
                        Button(action: { showingModelSelector = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "cube.fill")
                                    .font(.system(size: 12))
                                Text(viewModel.currentModel?.displayName ?? "Select Model")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isGenerating)
                        
                        Spacer()
                        
                        if viewModel.isGenerating {
                            Button(action: { viewModel.stopGeneration() }) {
                                Image(systemName: "stop.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    HStack(spacing: 12) {
                        TextField("Message", text: $messageText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .lineLimit(1...5)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                                    )
                            )
                        
                        Button(action: sendMessage) {
                            Image(systemName: trimmedMessageText.isEmpty ? "waveform" : "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(trimmedMessageText.isEmpty ? Color.secondary : Color.accentColor)
                        }
                        .disabled(trimmedMessageText.isEmpty || viewModel.isGenerating)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(.ultraThinMaterial)
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        pendingTitle = session.title
                        showingRenameDialog = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    
                    Button {
                        clearMessages()
                    } label: {
                        Label("Clear Messages", systemImage: "trash")
                    }
                    .disabled(viewModel.isGenerating)
                    
                    Button(role: .destructive) {
                        deleteChat()
                    } label: {
                        Label("Delete Chat", systemImage: "trash")
                    }
                    .disabled(viewModel.isGenerating)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingModelSelector) {
            ModelSelectorSheet(selectedModel: $viewModel.currentModel)
        }
        .task {
            syncCurrentModelSelection()
        }
        .onChange(of: downloadedModelRevision) { _ in
            syncCurrentModelSelection()
        }
        .onChange(of: viewModel.currentModel?.id) { _ in
            if let selectedModel = viewModel.currentModel {
                session.modelId = selectedModel.persistentReference
                session.updatedAt = Date()
                try? modelContext.save()
            } else if !session.modelId.isEmpty {
                session.modelId = ""
                session.updatedAt = Date()
                try? modelContext.save()
            }
        }
        .alert("Chat Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Rename Chat", isPresented: $showingRenameDialog) {
            TextField("Chat Title", text: $pendingTitle)
            Button("Save") {
                let trimmed = pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    session.title = trimmed
                    session.updatedAt = Date()
                    try? modelContext.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func clearMessages() {
        for message in session.orderedMessages {
            modelContext.delete(message)
        }
        session.messages = []
        session.updatedAt = Date()
        try? modelContext.save()
        Task { @MainActor in
            HapticManager.notification(.success)
        }
    }

    private func deleteChat() {
        modelContext.delete(session)
        try? modelContext.save()
        Task { @MainActor in
            HapticManager.notification(.warning)
        }
        dismiss()
    }
    
    private func sendMessage() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        messageText = ""

        Task { @MainActor in
            HapticManager.impact(.light)
        }
        
        Task {
            await viewModel.sendMessage(content, in: session, context: modelContext)
        }
    }

    private func syncCurrentModelSelection() {
        if let matchingModel = DownloadedModel.resolveStoredReference(session.modelId, in: downloadedModels) {
            if viewModel.currentModel?.id != matchingModel.id {
                viewModel.currentModel = matchingModel
            }
            return
        }

        if viewModel.currentModel != nil {
            viewModel.currentModel = nil
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @ObservedObject private var settings = AppSettings.shared
    
    var isUser: Bool {
        message.role == .user
    }
    
    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if !isUser {
                        Image(systemName: "cpu")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(isUser ? "You" : "Assistant")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    if isUser {
                        Image(systemName: "person.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                
                if settings.markdownRendering && !isUser {
                    MarkdownText(message.content)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(isUser ? Color.accentColor : .ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                                )
                        )
                        .foregroundStyle(isUser ? .white : .primary)
                } else {
                    Text(message.content)
                        .font(.system(size: 16))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(isUser ? Color.accentColor : .ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                                )
                        )
                        .foregroundStyle(isUser ? .white : .primary)
                }
                
                if (settings.showTokenCount || settings.showGenerationSpeed) && message.tokenCount > 0 {
                    HStack(spacing: 4) {
                        if settings.showTokenCount {
                            Text("\(message.tokenCount) tokens")
                                .font(.system(size: 10))
                        }

                        if settings.showGenerationSpeed && message.generationTime > 0 {
                            if settings.showTokenCount {
                                Text("•")
                            }
                            Text(String(format: "%.1f t/s", Double(message.tokenCount) / message.generationTime))
                                .font(.system(size: 10))
                        }
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            
            if !isUser { Spacer(minLength: 60) }
        }
    }
}

struct MarkdownText: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        Text(attributedString)
            .font(.system(size: 16))
    }
    
    private var attributedString: AttributedString {
        if let parsed = try? AttributedString(markdown: text) {
            return parsed
        }

        return AttributedString(text)
    }
}

struct TypingIndicator: View {
    @State private var phase = 0.0
    
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .offset(y: sin(phase + Double(i) * 0.5) * 3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.ultraThinMaterial)
            )
            
            Spacer(minLength: 60)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                phase = .pi * 2
            }
        }
    }
}

struct ModelSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<DownloadedModel> { $0.isDownloaded == true }) private var models: [DownloadedModel]
    @Binding var selectedModel: DownloadedModel?
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()
                
                List {
                    ForEach(models) { model in
                        Button {
                            selectedModel = model
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.displayName)
                                        .font(.system(size: 16, weight: .medium))
                                    
                                    HStack(spacing: 8) {
                                        Label(model.quantization, systemImage: "cpu")
                                            .font(.system(size: 12))
                                        
                                        Text("•")
                                        
                                        Label(model.formattedSize, systemImage: "externaldrive")
                                            .font(.system(size: 12))
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                if selectedModel?.id == model.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.ultraThinMaterial)
                        )
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published var isGenerating = false
    @Published var currentModel: DownloadedModel?
    @Published var errorMessage: String?
    @Published var streamRevision = 0
    
    func sendMessage(_ content: String, in session: ChatSession, context: ModelContext) async {
        guard let model = currentModel else {
            errorMessage = "No model selected"
            Task { @MainActor in
                HapticManager.notification(.error)
            }
            return
        }

        let existingPromptTurns = session.orderedMessages
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { PromptTurn(role: $0.roleValue, content: $0.content) }
        
        let userMessage = ChatMessage(role: .user, content: content)
        userMessage.session = session
        context.insert(userMessage)
        session.updatedAt = Date()

        try? context.save()

        let assistantMessage = ChatMessage(role: .assistant, content: "", isGenerating: true)
        assistantMessage.session = session
        context.insert(assistantMessage)
        try? context.save()

        isGenerating = true
        streamRevision = 0
        defer {
            isGenerating = false
        }

        let conversationPrompt = PromptComposer.compose(
            systemPrompt: nil,
            messages: existingPromptTurns + [PromptTurn(role: userMessage.roleValue, content: userMessage.content)]
        )
        
        do {
            // Validate model path before loading
            guard !model.localPath.isEmpty else {
                throw ModelError.invalidPath
            }
            
            // Check if file exists at the stored path
            guard FileManager.default.fileExists(atPath: model.localPath) else {
                throw ModelError.modelNotFound
            }
            
            try await ModelRunner.shared.loadModel(
                from: model.localPath,
                contextLength: model.runtimeContextLength,
                gpuLayers: AppSettings.shared.gpuLayers
            )
            
            var generatedText = ""
            let shouldStreamInUI = AppSettings.shared.streamingEnabled
            
            let result = try await ModelRunner.shared.generate(
                prompt: conversationPrompt,
                systemPrompt: session.systemPrompt
            ) { token in
                guard shouldStreamInUI else { return }
                generatedText += token
                Task { @MainActor in
                    assistantMessage.content = generatedText
                    self.streamRevision += 1
                }
            }
            
            assistantMessage.content = result.text
            assistantMessage.isGenerating = false
            assistantMessage.tokenCount = result.tokensGenerated
            assistantMessage.generationTime = result.generationTime
            streamRevision += 1
            
            session.updatedAt = Date()
            try? context.save()
            Task { @MainActor in
                if result.wasCancelled {
                    HapticManager.impact(.medium)
                } else {
                    HapticManager.notification(.success)
                }
            }
            
        } catch {
            errorMessage = error.localizedDescription
            assistantMessage.content = "Error: \(error.localizedDescription)"
            assistantMessage.isGenerating = false
            try? context.save()
            Task { @MainActor in
                HapticManager.notification(.error)
            }
        }
    }
    
    func stopGeneration() {
        ModelRunner.shared.stopGeneration()
        Task { @MainActor in
            HapticManager.impact(.medium)
        }
    }
}

#Preview {
    let session = ChatSession(modelId: "test")
    ChatView(session: session)
        .modelContainer(for: [ChatSession.self, ChatMessage.self, DownloadedModel.self], inMemory: true)
}
