import Foundation
import Network

actor ServerManager {
    static let shared = ServerManager()
    
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var isRunning = false
    
    private init() {}
    
    func startServerIfEnabled() async {
        guard AppSettings.shared.serverEnabled else { return }
        await startServer()
    }
    
    func startServer() async {
        guard !isRunning else { return }
        
        let port = NWEndpoint.Port(integerLiteral: UInt16(AppSettings.shared.serverPort))
        
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            print("Failed to create listener: \(error)")
            return
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("Server listening on port \(port)")
                self?.isRunning = true
            case .failed(let error):
                print("Server failed: \(error)")
                self?.isRunning = false
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener?.start(queue: .global())
    }
    
    func stopServer() {
        listener?.cancel()
        listener = nil
        
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        
        isRunning = false
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        
        connection.start(queue: .global())
        receiveHTTPRequest(on: connection)
    }
    
    private func receiveHTTPRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data else {
                connection.cancel()
                return
            }
            
            if let request = String(data: data, encoding: .utf8) {
                self.handleHTTPRequest(request, on: connection)
            }
            
            if isComplete {
                connection.cancel()
            } else {
                self.receiveHTTPRequest(on: connection)
            }
        }
    }
    
    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(status: 400, message: "Bad Request", on: connection)
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(status: 400, message: "Bad Request", on: connection)
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        
        // Check API key if required
        if AppSettings.shared.requireApiKey {
            let headers = parseHeaders(from: lines)
            guard let authHeader = headers["Authorization"],
                  authHeader == "Bearer \(AppSettings.shared.apiKey)" else {
                sendErrorResponse(status: 401, message: "Unauthorized", on: connection)
                return
            }
        }
        
        // Route the request
        switch (method, path) {
        case ("GET", "/api/tags"):
            handleListModels(on: connection)
        case ("POST", "/api/generate"):
            handleGenerate(request: request, on: connection)
        case ("POST", "/api/chat"):
            handleChat(request: request, on: connection)
        case ("POST", "/api/pull"):
            handlePull(request: request, on: connection)
        case ("DELETE", "/api/delete"):
            handleDelete(request: request, on: connection)
        case ("POST", "/api/embed"):
            handleEmbed(request: request, on: connection)
        case ("GET", "/api/ps"):
            handleRunningModels(on: connection)
        case ("GET", "/"):
            sendJSONResponse(status: 200, body: ["status": "OllamaKit Server Running"], on: connection)
        default:
            sendErrorResponse(status: 404, message: "Not Found", on: connection)
        }
    }
    
    private func handleListModels(on connection: NWConnection) {
        Task {
            let models = await ModelStorage.shared.getAllModels()
            let modelData = models.map { model in
                [
                    "name": model.name,
                    "model": model.modelId,
                    "size": model.size,
                    "modified_at": ISO8601DateFormatter().string(from: model.downloadDate),
                    "details": [
                        "parameter_size": model.parameters,
                        "quantization_level": model.quantization
                    ]
                ] as [String: Any]
            }
            
            sendJSONResponse(status: 200, body: ["models": modelData], on: connection)
        }
    }
    
    private func handleGenerate(request: String, on connection: NWConnection) {
        guard let body = extractBody(from: request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let modelName = json["model"] as? String,
              let prompt = json["prompt"] as? String else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection)
            return
        }
        
        let stream = json["stream"] as? Bool ?? false
        let options = json["options"] as? [String: Any] ?? [:]
        
        Task {
            guard let model = await ModelStorage.shared.getModel(name: modelName),
                  model.isDownloaded else {
                sendErrorResponse(status: 404, message: "Model not found", on: connection)
                return
            }
            
            // Load model if not loaded
            if !ModelRunner.shared.isLoaded {
                do {
                    try await ModelRunner.shared.loadModel(
                        from: model.localPath,
                        contextLength: model.contextLength,
                        gpuLayers: AppSettings.shared.gpuLayers
                    )
                } catch {
                    sendErrorResponse(status: 500, message: "Failed to load model", on: connection)
                    return
                }
            }
            
            if stream {
                await handleStreamingGenerate(
                    prompt: prompt,
                    model: modelName,
                    options: options,
                    on: connection
                )
            } else {
                await handleNonStreamingGenerate(
                    prompt: prompt,
                    model: modelName,
                    options: options,
                    on: connection
                )
            }
        }
    }
    
    private func handleStreamingGenerate(
        prompt: String,
        model: String,
        options: [String: Any],
        on connection: NWConnection
    ) async {
        var responseText = ""
        
        do {
            let _ = try await ModelRunner.shared.generate(
                prompt: prompt,
                parameters: ModelParameters.default
            ) { token in
                responseText += token
                
                let chunk: [String: Any] = [
                    "model": model,
                    "created_at": ISO8601DateFormatter().string(from: Date()),
                    "response": token,
                    "done": false
                ]
                
                self.sendSSEChunk(data: chunk, on: connection)
            }
            
            let finalChunk: [String: Any] = [
                "model": model,
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "response": "",
                "done": true,
                "total_duration": 0,
                "load_duration": 0,
                "prompt_eval_count": 0,
                "prompt_eval_duration": 0,
                "eval_count": 0,
                "eval_duration": 0
            ]
            
            sendSSEChunk(data: finalChunk, on: connection)
            
        } catch {
            sendErrorResponse(status: 500, message: "Generation failed", on: connection)
        }
    }
    
    private func handleNonStreamingGenerate(
        prompt: String,
        model: String,
        options: [String: Any],
        on connection: NWConnection
    ) async {
        do {
            let result = try await ModelRunner.shared.generate(
                prompt: prompt,
                parameters: ModelParameters.default
            ) { _ in }
            
            let response: [String: Any] = [
                "model": model,
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "response": result.text,
                "done": true,
                "total_duration": Int(result.generationTime * 1_000_000_000),
                "load_duration": 0,
                "prompt_eval_count": result.promptTokens,
                "prompt_eval_duration": 0,
                "eval_count": result.tokensGenerated,
                "eval_duration": Int(result.generationTime * 1_000_000_000)
            ]
            
            sendJSONResponse(status: 200, body: response, on: connection)
            
        } catch {
            sendErrorResponse(status: 500, message: "Generation failed", on: connection)
        }
    }
    
    private func handleChat(request: String, on connection: NWConnection) {
        // Similar to generate but with message history
        handleGenerate(request: request, on: connection)
    }
    
    private func handlePull(request: String, on connection: NWConnection) {
        // Handle model download request
        sendJSONResponse(status: 200, body: ["status": "pulling manifest"], on: connection)
    }
    
    private func handleDelete(request: String, on connection: NWConnection) {
        guard let body = extractBody(from: request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let modelName = json["name"] as? String else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection)
            return
        }
        
        Task {
            await ModelStorage.shared.deleteModel(name: modelName)
            sendJSONResponse(status: 200, body: [:], on: connection)
        }
    }
    
    private func handleEmbed(request: String, on connection: NWConnection) {
        sendErrorResponse(status: 501, message: "Not implemented", on: connection)
    }
    
    private func handleRunningModels(on connection: NWConnection) {
        Task {
            var models: [[String: Any]] = []
            
            if ModelRunner.shared.isLoaded {
                models.append([
                    "name": "current",
                    "model": "loaded",
                    "size": 0,
                    "size_vram": 0,
                    "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))
                ])
            }
            
            sendJSONResponse(status: 200, body: ["models": models], on: connection)
        }
    }
    
    // MARK: - Response Helpers
    
    private func sendJSONResponse(status: Int, body: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            sendErrorResponse(status: 500, message: "Internal Server Error", on: connection)
            return
        }
        
        let response = """
        HTTP/1.1 \(status) \(HTTPStatusText(status))
Content-Type: application/json
Content-Length: \(data.count)
Connection: close


        """
        
        let responseData = response.data(using: .utf8)! + data
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendSSEChunk(data: [String: Any], on connection: NWConnection) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        let chunk = "data: \(jsonString)\n\n"
        connection.send(content: chunk.data(using: .utf8), completion: .contentProcessed { _ in })
    }
    
    private func sendErrorResponse(status: Int, message: String, on connection: NWConnection) {
        let body: [String: Any] = ["error": message]
        sendJSONResponse(status: status, body: body, on: connection)
    }
    
    private func extractBody(from request: String) -> Data? {
        let parts = request.components(separatedBy: "\r\n\r\n")
        guard parts.count > 1 else { return nil }
        return parts[1].data(using: .utf8)
    }
    
    private func parseHeaders(from lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let parts = line.components(separatedBy: ": ")
            if parts.count == 2 {
                headers[parts[0]] = parts[1]
            }
        }
        
        return headers
    }
    
    private func HTTPStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Unknown"
        }
    }
    
    var serverURL: String {
        AppSettings.shared.serverURL
    }
    
    var isServerRunning: Bool {
        isRunning
    }
}

actor ModelStorage {
    static let shared = ModelStorage()
    
    private init() {}
    
    func getAllModels() async -> [DownloadedModel] {
        // This would fetch from SwiftData
        // Placeholder implementation
        return []
    }
    
    func getModel(name: String) async -> DownloadedModel? {
        // Placeholder implementation
        return nil
    }
    
    func deleteModel(name: String) async {
        // Placeholder implementation
    }
}
