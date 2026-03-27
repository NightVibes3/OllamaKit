import SwiftUI

struct ServerView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var viewModel = ServerViewModel()
    
    var body: some View {
        ZStack {
            AnimatedMeshBackground()
            
            List {
                // Server Status Card
                Section {
                    ServerStatusCard(viewModel: viewModel)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                
                // Connection Info
                Section {
                    ConnectionInfoCard(viewModel: viewModel)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                
                // Server Settings
                Section {
                    ServerSettingsSection(settings: settings)
                } header: {
                    Text("Server Configuration")
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                )
                .listRowSeparator(.hidden)
                
                // Security Settings
                Section {
                    SecuritySettingsSection(settings: settings)
                } header: {
                    Text("Security")
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                )
                .listRowSeparator(.hidden)
                
                // API Documentation
                Section {
                    APIDocsSection()
                } header: {
                    Text("API")
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
        .navigationTitle("Server")
        .onAppear {
            viewModel.refreshStatus()
        }
    }
}

struct ServerStatusCard: View {
    @ObservedObject var viewModel: ServerViewModel
    
    var statusColor: Color {
        viewModel.isRunning ? .green : .red
    }
    
    var statusText: String {
        viewModel.isRunning ? "Running" : "Stopped"
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 100, height: 100)
                
                Circle()
                    .fill(statusColor.opacity(0.3))
                    .frame(width: 80, height: 80)
                
                Image(systemName: viewModel.isRunning ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(statusColor)
            }
            .overlay(
                Circle()
                    .stroke(statusColor.opacity(0.5), lineWidth: 2)
            )
            
            VStack(spacing: 8) {
                Text(statusText)
                    .font(.system(size: 28, weight: .bold))
                
                if viewModel.isRunning {
                    Text("OllamaKit API Server")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                    
                    Text("Port \(AppSettings.shared.serverPort)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                }
            }
            
            // Toggle button
            Button {
                Task {
                    if viewModel.isRunning {
                        await viewModel.stopServer()
                    } else {
                        await viewModel.startServer()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                    Text(viewModel.isRunning ? "Stop Server" : "Start Server")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(viewModel.isRunning ? Color.red : Color.accentColor)
                )
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct ConnectionInfoCard: View {
    @ObservedObject var viewModel: ServerViewModel
    @State private var showingCopiedAlert = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 20))
                    .foregroundStyle(.accent)
                
                Text("Connection URLs")
                    .font(.system(size: 20, weight: .bold))
                
                Spacer()
            }
            
            VStack(spacing: 12) {
                URLRow(
                    label: "Local",
                    url: AppSettings.shared.localServerURL,
                    description: "For apps on this device"
                )
                
                if AppSettings.shared.allowExternalConnections {
                    Divider()
                    
                    URLRow(
                        label: "Network",
                        url: viewModel.networkURL,
                        description: "For other devices on your network"
                    )
                }
            }
        }
        .padding(20)
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

struct URLRow: View {
    let label: String
    let url: String
    let description: String
    
    @State private var showingCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                
                Spacer()
                
                Button {
                    UIPasteboard.general.string = url
                    withAnimation {
                        showingCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            showingCopied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showingCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                        Text(showingCopied ? "Copied" : "Copy")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.accent)
                }
            }
            
            Text(url)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
            
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
}

struct ServerSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var showingPortPicker = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Port setting
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server Port")
                        .font(.system(size: 16, weight: .medium))
                    Text("Port for the API server")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    showingPortPicker = true
                } label: {
                    Text("\(settings.serverPort)")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.ultraThinMaterial)
                        )
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            // Auto-start toggle
            Toggle(isOn: $settings.serverEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-start Server")
                        .font(.system(size: 16, weight: .medium))
                    Text("Start server when app launches")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            // External connections toggle
            Toggle(isOn: $settings.allowExternalConnections) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow External Connections")
                        .font(.system(size: 16, weight: .medium))
                    Text("Allow other devices to connect")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showingPortPicker) {
            PortPickerSheet(port: $settings.serverPort)
        }
    }
}

struct SecuritySettingsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var showingAPIKey = false
    
    var body: some View {
        VStack(spacing: 0) {
            // API Key toggle
            Toggle(isOn: $settings.requireApiKey) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Require API Key")
                        .font(.system(size: 16, weight: .medium))
                    Text("Protect server with authentication")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            
            if settings.requireApiKey {
                Divider()
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.system(size: 16, weight: .medium))
                        Text("Use this key in API requests")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        Text(showingAPIKey ? settings.apiKey : String(repeating: "•", count: 16))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        
                        Button {
                            showingAPIKey.toggle()
                        } label: {
                            Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        
                        Button {
                            UIPasteboard.general.string = settings.apiKey
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14))
                                .foregroundStyle(.accent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.ultraThinMaterial)
                    )
                }
                .padding(.vertical, 12)
                
                Divider()
                
                Button {
                    settings.apiKey = UUID().uuidString.prefix(16).uppercased()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Regenerate API Key")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.accent)
                }
                .padding(.vertical, 12)
            }
        }
    }
}

struct APIDocsSection: View {
    @State private var showingDocs = false
    
    let endpoints = [
        ("GET", "/api/tags", "List available models"),
        ("POST", "/api/generate", "Generate text completion"),
        ("POST", "/api/chat", "Chat completion"),
        ("POST", "/api/embed", "Generate embeddings"),
        ("POST", "/api/pull", "Download a model"),
        ("DELETE", "/api/delete", "Delete a model"),
        ("GET", "/api/ps", "List running models")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            Button {
                showingDocs = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Documentation")
                            .font(.system(size: 16, weight: .medium))
                        Text("View available endpoints")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 12)
            
            Divider()
            
            // Quick endpoint list
            VStack(alignment: .leading, spacing: 8) {
                Text("Endpoints")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                
                ForEach(endpoints, id: \.1) { method, path, desc in
                    HStack(spacing: 8) {
                        Text(method)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(methodColor(method))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(methodColor(method).opacity(0.2))
                            )
                        
                        Text(path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showingDocs) {
            APIDocumentationView()
        }
    }
    
    func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "DELETE": return .red
        default: return .gray
        }
    }
}

struct PortPickerSheet: View {
    @Binding var port: Int
    @Environment(\.dismiss) private var dismiss
    @State private var tempPort: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Port", text: $tempPort)
                        .keyboardType(.numberPad)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                } header: {
                    Text("Server Port (1024-65535)")
                }
                
                Section {
                    Button("Use Default (11434)") {
                        tempPort = "11434"
                    }
                    .foregroundStyle(.accent)
                }
            }
            .navigationTitle("Server Port")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let newPort = Int(tempPort), newPort >= 1024, newPort <= 65535 {
                            port = newPort
                        }
                        dismiss()
                    }
                    .disabled(Int(tempPort) == nil)
                }
            }
            .onAppear {
                tempPort = String(port)
            }
        }
    }
}

struct APIDocumentationView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Introduction
                    DocSection(title: "Introduction") {
                        Text("OllamaKit provides an OpenAI-compatible API for running local LLMs. The server runs on your device and can be accessed by other applications.")
                            .font(.system(size: 15))
                    }
                    
                    // Authentication
                    DocSection(title: "Authentication") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("If API key is enabled, include it in the Authorization header:")
                                .font(.system(size: 15))
                            
                            CodeBlock(code: "Authorization: Bearer YOUR_API_KEY")
                        }
                    }
                    
                    // Endpoints
                    DocSection(title: "Endpoints") {
                        VStack(alignment: .leading, spacing: 16) {
                            EndpointDoc(
                                method: "GET",
                                path: "/api/tags",
                                description: "List all downloaded models",
                                example: """
                                curl http://localhost:11434/api/tags
                                """
                            )
                            
                            EndpointDoc(
                                method: "POST",
                                path: "/api/generate",
                                description: "Generate a completion",
                                example: """
                                curl -X POST http://localhost:11434/api/generate \\
                                  -H "Content-Type: application/json" \\
                                  -d '{
                                    "model": "llama2",
                                    "prompt": "Why is the sky blue?"
                                  }'
                                """
                            )
                            
                            EndpointDoc(
                                method: "POST",
                                path: "/api/chat",
                                description: "Chat completion with message history",
                                example: """
                                curl -X POST http://localhost:11434/api/chat \\
                                  -H "Content-Type: application/json" \\
                                  -d '{
                                    "model": "llama2",
                                    "messages": [
                                      {"role": "user", "content": "Hello!"}
                                    ]
                                  }'
                                """
                            )
                        }
                    }
                    
                    // Parameters
                    DocSection(title: "Generation Parameters") {
                        VStack(alignment: .leading, spacing: 8) {
                            ParameterRow(name: "temperature", type: "float", default: "0.7", description: "Sampling temperature")
                            ParameterRow(name: "top_p", type: "float", default: "0.9", description: "Nucleus sampling")
                            ParameterRow(name: "top_k", type: "int", default: "40", description: "Top-k sampling")
                            ParameterRow(name: "repeat_penalty", type: "float", default: "1.1", description: "Repetition penalty")
                            ParameterRow(name: "max_tokens", type: "int", default: "-1", description: "Max tokens to generate")
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("API Documentation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct DocSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            
            content
        }
    }
}

struct CodeBlock: View {
    let code: String
    
    var body: some View {
        Text(code)
            .font(.system(size: 13, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.1), lineWidth: 0.5)
            )
    }
}

struct EndpointDoc: View {
    let method: String
    let path: String
    let description: String
    let example: String
    
    var methodColor: Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "DELETE": return .red
        default: return .gray
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(method)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(methodColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(methodColor.opacity(0.2))
                    )
                
                Text(path)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
            }
            
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            
            CodeBlock(code: example)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
}

struct ParameterRow: View {
    let name: String
    let type: String
    let `default`: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                
                HStack(spacing: 4) {
                    Text(type)
                        .font(.system(size: 11))
                        .foregroundStyle(.accent)
                    
                    Text("default: \(`default`)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, alignment: .leading)
            
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
class ServerViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var networkURL = ""
    
    func refreshStatus() {
        Task {
            isRunning = await ServerManager.shared.isServerRunning
            updateNetworkURL()
        }
    }
    
    func startServer() async {
        await ServerManager.shared.startServer()
        isRunning = await ServerManager.shared.isServerRunning
        updateNetworkURL()
    }
    
    func stopServer() async {
        await ServerManager.shared.stopServer()
        isRunning = await ServerManager.shared.isServerRunning
    }
    
    private func updateNetworkURL() {
        // Get device IP address
        var address = "Unknown"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let flags = Int32(ptr!.pointee.ifa_flags)
                let addr = ptr!.pointee.ifa_addr.pointee
                
                if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                    if addr.sa_family == UInt8(AF_INET) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(ptr!.pointee.ifa_addr, socklen_t(addr.sa_len),
                                      &hostname, socklen_t(hostname.count),
                                      nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                            let ip = String(cString: hostname)
                            if ip != "127.0.0.1" {
                                address = ip
                                break
                            }
                        }
                    }
                }
                ptr = ptr!.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        
        networkURL = "http://\(address):\(AppSettings.shared.serverPort)"
    }
}

#Preview {
    ServerView()
}
