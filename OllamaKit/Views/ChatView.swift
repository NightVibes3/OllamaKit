import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var session: ChatSession
    
    @StateObject private var viewModel = ChatViewModel()
    @State private var messageText = ""
    @State private var showingModelSelector = false
    @State private var scrollToBottom = false
    
    @Namespace private var bottomID
    
    var body: some View {
        ZStack {
            AnimatedMeshBackground()
            
            VStack(spacing: 0) {
                // Messages List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(session.messages ?? [], id: \.id) { message in
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
                    .onChange(of: session.messages?.count) { _ in
                        withAnimation {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.isGenerating) { _ in
                        withAnimation {
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
                            Image(systemName: messageText.isEmpty ? "waveform" : "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(messageText.isEmpty ? .secondary : .accent)
                        }
                        .disabled(messageText.isEmpty && !viewModel.isGenerating)
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
                        // Rename chat
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    
                    Button {
                        // Clear messages
                    } label: {
                        Label("Clear Messages", systemImage: "trash")
                    }
                    
                    Button(role: .destructive) {
                        // Delete chat
                    } label: {
                        Label("Delete Chat", systemImage: "delete.left")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingModelSelector) {
            ModelSelectorSheet(selectedModel: $viewModel.currentModel)
        }
        .task {
            await viewModel.loadModel(for: session)
        }
    }
    
    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        
        let content = messageText
        messageText = ""
        
        Task {
            await viewModel.sendMessage(content, in: session, context: modelContext)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @StateObject private var settings = AppSettings.shared
    
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
                
                if settings.showTokenCount && message.tokenCount > 0 {
                    HStack(spacing: 4) {
                        Text("\(message.tokenCount) tokens")
                            .font(.system(size: 10))
                        
                        if message.generationTime > 0 {
                            Text("•")
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
        // Simple markdown parsing - in production, use a proper markdown parser
        var result = text
        
        // Code blocks
        result = result.replacingOccurrences(of: "```\\n?([^`]+)\\n?```", with: "$1", options: .regularExpression)
        
        // Inline code
        result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        
        // Bold
        result = result.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        
        // Italic
        result = result.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        
        return AttributedString(result)
    }
}

struct TypingIndicator: View {
    @State private var phase = 0
    
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
                                        .foregroundStyle(.accent)
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
    
    func loadModel(for session: ChatSession) async {
        // Load the model associated with this session
        // This is a placeholder - in production, fetch from SwiftData
    }
    
    func sendMessage(_ content: String, in session: ChatSession, context: ModelContext) async {
        guard let model = currentModel else {
            errorMessage = "No model selected"
            return
        }
        
        // Create user message
        let userMessage = ChatMessage(role: .user, content: content)
        userMessage.session = session
        context.insert(userMessage)
        
        if session.messages == nil {
            session.messages = []
        }
        session.messages?.append(userMessage)
        session.updatedAt = Date()
        
        try? context.save()
        
        // Create assistant message placeholder
        let assistantMessage = ChatMessage(role: .assistant, content: "", isGenerating: true)
        assistantMessage.session = session
        context.insert(assistantMessage)
        session.messages?.append(assistantMessage)
        
        isGenerating = true
        
        do {
            // Validate model path before loading
            guard !model.localPath.isEmpty else {
                throw ModelError.invalidPath
            }
            
            // Check if file exists at the stored path
            guard FileManager.default.fileExists(atPath: model.localPath) else {
                throw ModelError.modelNotFound
            }
            
            // Load model if needed
            if !ModelRunner.shared.isLoaded || ModelRunner.shared.loadedModelPath != model.localPath {
                try await ModelRunner.shared.loadModel(
                    from: model.localPath,
                    contextLength: model.contextLength,
                    gpuLayers: AppSettings.shared.gpuLayers
                )
            }
            
            var generatedText = ""
            let startTime = CFAbsoluteTimeGetCurrent()
            
            let result = try await ModelRunner.shared.generate(
                prompt: content,
                systemPrompt: session.systemPrompt
            ) { token in
                generatedText += token
                Task { @MainActor in
                    assistantMessage.content = generatedText
                }
            }
            
            assistantMessage.content = result.text
            assistantMessage.isGenerating = false
            assistantMessage.tokenCount = result.tokensGenerated
            assistantMessage.generationTime = result.generationTime
            
            session.updatedAt = Date()
            try? context.save()
            
        } catch {
            errorMessage = error.localizedDescription
            assistantMessage.content = "Error: \(error.localizedDescription)"
            assistantMessage.isGenerating = false
            try? context.save()
        }
        
        isGenerating = false
    }
    
    func stopGeneration() {
        Task {
            await ModelRunner.shared.stopGeneration()
        }
        isGenerating = false
    }
}

#Preview {
    let session = ChatSession(modelId: "test")
    ChatView(session: session)
        .modelContainer(for: [ChatSession.self, ChatMessage.self, DownloadedModel.self], inMemory: true)
}
