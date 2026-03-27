import Foundation
import Network
import SwiftData

final class ServerManager {
    static let shared = ServerManager()
    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let iso8601FormatterLock = NSLock()

    private let queue = DispatchQueue(label: "com.ollamakit.server", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var isRunning = false
    private var isStarting = false
    private var startupContinuation: CheckedContinuation<Void, Never>?

    private init() {}

    func startServerIfEnabled() async {
        guard AppSettings.shared.serverEnabled else { return }
        await startServer()
    }

    func startServer() async {
        stateLock.lock()
        let canStart = !isRunning && !isStarting && listener == nil
        if canStart {
            isStarting = true
        }
        stateLock.unlock()
        guard canStart else { return }

        let configuredPort = AppSettings.shared.serverPort
        guard (1024...Int(UInt16.max)).contains(configuredPort),
              let port = NWEndpoint.Port(rawValue: UInt16(configuredPort))
        else {
            stateLock.lock()
            isStarting = false
            stateLock.unlock()
            print("Invalid server port: \(configuredPort)")
            return
        }

        do {
            let newListener = try NWListener(using: .tcp, on: port)
            let resumeLock = NSLock()
            var didResume = false

            func resumeStartupIfNeeded(_ continuation: CheckedContinuation<Void, Never>) {
                resumeLock.lock()
                defer { resumeLock.unlock() }

                guard !didResume else { return }
                didResume = true
                continuation.resume()
            }

            newListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, port: port)

                switch state {
                case .ready, .failed, .cancelled:
                    guard let self else { return }
                    self.stateLock.lock()
                    let continuation = self.startupContinuation
                    self.startupContinuation = nil
                    self.stateLock.unlock()
                    if let continuation {
                        resumeStartupIfNeeded(continuation)
                    }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            stateLock.lock()
            listener = newListener
            stateLock.unlock()
            await withCheckedContinuation { continuation in
                stateLock.lock()
                startupContinuation = continuation
                stateLock.unlock()
                newListener.start(queue: queue)
            }
        } catch {
            stateLock.lock()
            isStarting = false
            stateLock.unlock()
            print("Failed to create listener: \(error)")
        }
    }

    func stopServer() async {
        stateLock.lock()
        let currentListener = listener
        listener = nil
        let activeConnections = Array(connections.values)
        connections.removeAll()
        isRunning = false
        isStarting = false
        let continuation = startupContinuation
        startupContinuation = nil
        stateLock.unlock()

        currentListener?.cancel()

        for connection in activeConnections {
            connection.cancel()
        }

        continuation?.resume()
    }

    func restartServerIfRunning() async {
        guard isServerRunning else { return }
        await stopServer()
        await startServer()
    }

    var serverURL: String {
        AppSettings.shared.serverURL
    }

    var isServerRunning: Bool {
        stateLock.lock()
        let currentValue = isRunning
        stateLock.unlock()
        return currentValue
    }

    private func handleListenerState(_ state: NWListener.State, port: NWEndpoint.Port) {
        switch state {
        case .ready:
            stateLock.lock()
            isRunning = true
            isStarting = false
            stateLock.unlock()
            print("Server listening on port \(port)")
        case .failed(let error):
            stateLock.lock()
            isRunning = false
            isStarting = false
            listener = nil
            stateLock.unlock()
            print("Server failed: \(error)")
        case .cancelled:
            stateLock.lock()
            isRunning = false
            isStarting = false
            listener = nil
            stateLock.unlock()
        default:
            break
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        stateLock.lock()
        connections[ObjectIdentifier(connection)] = connection
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                guard let self else { return }
                self.stateLock.lock()
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
                self.stateLock.unlock()
            default:
                break
            }
        }

        connection.start(queue: queue)

        guard allowsConnection(connection) else {
            sendErrorResponse(
                status: 403,
                message: "External connections are disabled. Enable Allow External Connections to accept non-local requests.",
                on: connection
            )
            return
        }

        receiveHTTPRequest(on: connection)
    }

    private func allowsConnection(_ connection: NWConnection) -> Bool {
        guard !AppSettings.shared.allowExternalConnections else { return true }

        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint

        switch endpoint {
        case .hostPort(let host, _):
            return isLoopback(host)
        case .service(name: _, type: _, domain: _, interface: _), .unix(path: _), .url(_), .opaque(_):
            return false
        @unknown default:
            return false
        }
    }

    private func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return address.debugDescription == "127.0.0.1"
        case .ipv6(let address):
            let rendered = address.debugDescription.lowercased()
            return rendered == "::1" || rendered == "0:0:0:0:0:0:0:1"
        case .name(let name, _):
            let lowered = name.lowercased()
            return lowered == "localhost" || lowered == "127.0.0.1"
        @unknown default:
            return false
        }
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        receiveHTTPRequest(on: connection, buffer: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if let requestLength = self.requestLengthIfComplete(in: accumulated) {
                let requestData = accumulated.prefix(requestLength)

                guard let request = String(data: requestData, encoding: .utf8) else {
                    self.sendErrorResponse(status: 400, message: "Bad Request", on: connection)
                    return
                }

                self.handleHTTPRequest(request, on: connection)
                return
            }

            if isComplete {
                self.sendErrorResponse(status: 400, message: "Bad Request", on: connection)
                return
            }

            self.receiveHTTPRequest(on: connection, buffer: accumulated)
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
        let rawPath = parts[1]
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let headers = parseHeaders(from: lines)

        if method == "OPTIONS" {
            sendCORSPreflightResponse(on: connection)
            return
        }

        if AppSettings.shared.requireApiKey {
            let authHeader = headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
            guard authHeader == "Bearer \(AppSettings.shared.apiKey)" else {
                if path.hasPrefix("/v1/") {
                    sendOpenAIErrorResponse(status: 401, message: "Unauthorized", type: "authentication_error", on: connection)
                } else {
                    sendErrorResponse(status: 401, message: "Unauthorized", on: connection)
                }
                return
            }
        }

        switch (method, path) {
        case ("GET", "/api/tags"):
            handleLegacyListModels(on: connection)
        case ("POST", "/api/generate"):
            handleLegacyGenerate(request: request, on: connection)
        case ("POST", "/api/chat"):
            handleLegacyChat(request: request, on: connection)
        case ("POST", "/api/pull"):
            handlePull(request: request, on: connection)
        case ("DELETE", "/api/delete"):
            handleDelete(request: request, on: connection)
        case ("POST", "/api/embed"):
            sendErrorResponse(status: 501, message: "Embeddings are not implemented in this build.", on: connection)
        case ("GET", "/api/ps"):
            handleRunningModels(on: connection)
        case ("GET", "/v1/models"):
            handleOpenAIListModels(on: connection)
        case ("POST", "/v1/completions"):
            handleOpenAICompletion(request: request, on: connection)
        case ("POST", "/v1/chat/completions"):
            handleOpenAIChatCompletion(request: request, on: connection)
        case ("POST", "/v1/embeddings"):
            sendOpenAIErrorResponse(status: 501, message: "Embeddings are not implemented in this build.", type: "not_implemented_error", on: connection)
        case ("GET", "/"):
            sendJSONResponse(
                status: 200,
                body: [
                    "status": "OllamaKit Server Running",
                    "ollama_compatible": true,
                    "openai_compatible_routes": ["/v1/models", "/v1/completions", "/v1/chat/completions"]
                ],
                on: connection
            )
        default:
            if path.hasPrefix("/v1/") {
                sendOpenAIErrorResponse(status: 404, message: "Not Found", type: "invalid_request_error", on: connection)
            } else {
                sendErrorResponse(status: 404, message: "Not Found", on: connection)
            }
        }
    }

    private func handleLegacyListModels(on connection: NWConnection) {
        Task {
            let models = await MainActor.run { ModelStorage.shared.allSnapshots() }
            let body: [String: Any] = [
                "models": models.map { snapshot in
                    let identifier = legacyModelName(for: snapshot)
                    return [
                        "name": identifier,
                        "model": identifier,
                        "size": snapshot.size,
                        "modified_at": iso8601String(from: snapshot.downloadDate),
                        "details": [
                            "parameter_size": snapshot.parameters,
                            "quantization_level": snapshot.quantization
                        ]
                    ]
                }
            ]

            sendJSONResponse(status: 200, body: body, on: connection)
        }
    }

    private func handleOpenAIListModels(on connection: NWConnection) {
        Task {
            let models = await MainActor.run { ModelStorage.shared.allSnapshots() }
            let createdAt = Int(Date().timeIntervalSince1970)
            let body: [String: Any] = [
                "object": "list",
                "data": models.map { snapshot in
                    [
                        "id": openAIModelIdentifier(for: snapshot),
                        "object": "model",
                        "created": createdAt,
                        "owned_by": "local"
                    ]
                }
            ]

            sendJSONResponse(status: 200, body: body, on: connection)
        }
    }

    private func handleLegacyGenerate(request: String, on connection: NWConnection) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = json["model"] as? String
        else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection)
            return
        }

        let prompt = extractStringContent(from: json["prompt"]) ?? ""
        let systemPrompt = extractStringContent(from: json["system"])
        let stream = json["stream"] as? Bool ?? true

        Task {
            do {
                let model = try await prepareModel(named: modelName)
                let parameters = modelParameters(from: json, apiStyle: .ollama)

                if stream {
                    await streamLegacyGenerate(
                        prompt: prompt,
                        systemPrompt: systemPrompt,
                        model: legacyModelName(for: model),
                        parameters: parameters,
                        on: connection
                    )
                } else {
                    await completeLegacyGenerate(
                        prompt: prompt,
                        systemPrompt: systemPrompt,
                        model: legacyModelName(for: model),
                        parameters: parameters,
                        on: connection
                    )
                }
            } catch {
                sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection)
            }
        }
    }

    private func handleLegacyChat(request: String, on connection: NWConnection) {
        guard
            let json = decodeJSONObject(from: request),
            let messages = json["messages"] as? [[String: Any]],
            let modelName = json["model"] as? String
        else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection)
            return
        }

        let systemPrompt = messages
            .filter { isInstructionRole($0["role"] as? String) }
            .compactMap { extractStringContent(from: $0["content"]) }
            .joined(separator: "\n\n")

        let conversationPrompt = PromptComposer.compose(
            messages: messages.compactMap { message in
                guard let role = message["role"] as? String,
                      !isInstructionRole(role),
                      let content = extractStringContent(from: message["content"])
                else {
                    return nil
                }

                return PromptTurn(role: role, content: content)
            },
            appendAssistantCue: true
        )

        let stream = json["stream"] as? Bool ?? true

        Task {
            do {
                let model = try await prepareModel(named: modelName)
                let parameters = modelParameters(from: json, apiStyle: .ollama)

                if stream {
                    await streamLegacyChat(
                        prompt: conversationPrompt,
                        systemPrompt: systemPrompt.nonEmpty,
                        model: legacyModelName(for: model),
                        parameters: parameters,
                        on: connection
                    )
                } else {
                    await completeLegacyChat(
                        prompt: conversationPrompt,
                        systemPrompt: systemPrompt.nonEmpty,
                        model: legacyModelName(for: model),
                        parameters: parameters,
                        on: connection
                    )
                }
            } catch {
                sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection)
            }
        }
    }

    private func handleOpenAICompletion(request: String, on connection: NWConnection) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = json["model"] as? String
        else {
            sendOpenAIErrorResponse(status: 400, message: "Invalid request", on: connection)
            return
        }

        let prompt: String
        if let promptString = extractStringContent(from: json["prompt"]) {
            prompt = promptString
        } else if let prompts = json["prompt"] as? [String] {
            prompt = prompts.joined(separator: "\n\n")
        } else {
            prompt = ""
        }

        let stream = json["stream"] as? Bool ?? false

        Task {
            do {
                let model = try await prepareModel(named: modelName)
                let parameters = modelParameters(from: json, apiStyle: .openAI)
                let requestId = "cmpl-\(UUID().uuidString.lowercased())"
                let createdAt = Int(Date().timeIntervalSince1970)
                let responseModel = openAIModelIdentifier(for: model)

                if stream {
                    await streamOpenAICompletion(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        prompt: prompt,
                        parameters: parameters,
                        on: connection
                    )
                } else {
                    await completeOpenAICompletion(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        prompt: prompt,
                        parameters: parameters,
                        on: connection
                    )
                }
            } catch {
                let status = httpStatus(for: error)
                sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection)
            }
        }
    }

    private func handleOpenAIChatCompletion(request: String, on connection: NWConnection) {
        guard
            let json = decodeJSONObject(from: request),
            let messages = json["messages"] as? [[String: Any]],
            let modelName = json["model"] as? String
        else {
            sendOpenAIErrorResponse(status: 400, message: "Invalid request", on: connection)
            return
        }

        let systemPrompt = messages
            .filter { isInstructionRole($0["role"] as? String) }
            .compactMap { extractStringContent(from: $0["content"]) }
            .joined(separator: "\n\n")

        let prompt = PromptComposer.compose(
            messages: messages.compactMap { message in
                guard let role = message["role"] as? String,
                      !isInstructionRole(role),
                      let content = extractStringContent(from: message["content"])
                else {
                    return nil
                }

                return PromptTurn(role: role, content: content)
            },
            appendAssistantCue: true
        )

        let stream = json["stream"] as? Bool ?? false

        Task {
            do {
                let model = try await prepareModel(named: modelName)
                let parameters = modelParameters(from: json, apiStyle: .openAI)
                let requestId = "chatcmpl-\(UUID().uuidString.lowercased())"
                let createdAt = Int(Date().timeIntervalSince1970)
                let responseModel = openAIModelIdentifier(for: model)

                if stream {
                    await streamOpenAIChatCompletion(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        prompt: prompt,
                        systemPrompt: systemPrompt.nonEmpty,
                        parameters: parameters,
                        on: connection
                    )
                } else {
                    await completeOpenAIChatCompletion(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        prompt: prompt,
                        systemPrompt: systemPrompt.nonEmpty,
                        parameters: parameters,
                        on: connection
                    )
                }
            } catch {
                let status = httpStatus(for: error)
                sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection)
            }
        }
    }

    private func handlePull(request: String, on connection: NWConnection) {
        guard let json = decodeJSONObject(from: request) else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection)
            return
        }

        let requestedName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestedFilename = (json["file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (json["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stream = json["stream"] as? Bool ?? true

        guard !requestedName.isEmpty else {
            sendPullError(stream: stream, status: 400, message: "Missing model name", on: connection)
            return
        }

        Task {
            if stream {
                sendStreamHeaders(contentType: "application/x-ndjson", on: connection)
                sendNDJSONChunk(
                    data: [
                        "status": "pulling",
                        "model": requestedName,
                        "done": false
                    ],
                    on: connection,
                    closeAfterSend: false
                )
            }

            do {
                let modelId = try await resolvePullModelID(from: requestedName)
                let files = try await HuggingFaceService.shared.getModelFiles(modelId: modelId)

                guard !files.isEmpty else {
                    if stream {
                        sendNDJSONChunk(
                            data: [
                                "error": "No GGUF files found for \(modelId).",
                                "done": true
                            ],
                            on: connection,
                            closeAfterSend: true
                        )
                    } else {
                        sendErrorResponse(status: 404, message: "No GGUF files found for \(modelId).", on: connection)
                    }
                    return
                }

                let file = selectFile(for: requestedFilename, from: files)
                guard let file else {
                    if stream {
                        sendNDJSONChunk(
                            data: [
                                "error": "Requested GGUF file was not found for \(modelId).",
                                "done": true
                            ],
                            on: connection,
                            closeAfterSend: true
                        )
                    } else {
                        sendErrorResponse(status: 404, message: "Requested GGUF file was not found for \(modelId).", on: connection)
                    }
                    return
                }

                let downloadedModel = try await HuggingFaceService.shared.downloadModel(
                    from: file.url,
                    filename: file.filename,
                    modelId: modelId
                ) { _ in }

                await MainActor.run {
                    ModelStorage.shared.upsertDownloadedModel(downloadedModel)
                }

                let finalBody: [String: Any] = [
                    "status": "success",
                    "model": downloadedModel.apiIdentifier,
                    "file": file.filename,
                    "size": downloadedModel.size,
                    "completed": downloadedModel.size,
                    "done": true
                ]

                if stream {
                    sendNDJSONChunk(data: finalBody, on: connection, closeAfterSend: true)
                } else {
                    sendJSONResponse(status: 200, body: finalBody, on: connection)
                }
            } catch {
                if stream {
                    sendNDJSONChunk(
                        data: [
                            "error": error.localizedDescription,
                            "done": true
                        ],
                        on: connection,
                        closeAfterSend: true
                    )
                } else {
                    sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection)
                }
            }
        }
    }

    private func handleDelete(request: String, on connection: NWConnection) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = json["name"] as? String
        else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection)
            return
        }

        Task {
            let didDelete = await MainActor.run {
                ModelStorage.shared.deleteModel(name: modelName)
            }

            if didDelete {
                sendJSONResponse(status: 200, body: [:], on: connection)
            } else {
                sendErrorResponse(status: 404, message: "Model not found", on: connection)
            }
        }
    }

    private func handleRunningModels(on connection: NWConnection) {
        Task {
            let models: [[String: Any]]

            if ModelRunner.shared.isLoaded, let path = ModelRunner.shared.loadedModelPath {
                let snapshots = await MainActor.run { ModelStorage.shared.allSnapshots() }
                let snapshot = snapshots.first { $0.localPath == path }
                let fallbackSnapshot = ModelSnapshot(
                    id: UUID(),
                    name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    modelId: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    localPath: path,
                    size: 0,
                    downloadDate: .now,
                    isDownloaded: true,
                    quantization: "GGUF",
                    parameters: "Unknown",
                    contextLength: AppSettings.shared.defaultContextLength
                )
                let resolvedSnapshot = snapshot ?? fallbackSnapshot
                let expiresAt: Any = AppSettings.shared.keepModelInMemory
                    ? NSNull()
                    : iso8601String(from: Date().addingTimeInterval(TimeInterval(AppSettings.shared.autoOffloadMinutes * 60)))

                models = [[
                    "name": legacyModelName(for: resolvedSnapshot),
                    "model": legacyModelName(for: resolvedSnapshot),
                    "size": snapshot?.size ?? 0,
                    "size_vram": 0,
                    "expires_at": expiresAt
                ]]
            } else {
                models = []
            }

            sendJSONResponse(status: 200, body: ["models": models], on: connection)
        }
    }

    private func prepareModel(named modelName: String) async throws -> ModelSnapshot {
        guard let model = await MainActor.run(body: { ModelStorage.shared.snapshot(name: modelName) }) else {
            throw NSError(domain: "ServerManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model not found"])
        }

        guard !model.localPath.isEmpty else {
            throw NSError(domain: "ServerManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Invalid model path"])
        }

        guard model.fileExists else {
            throw NSError(domain: "ServerManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model file not found. Please re-download the model."])
        }

        try await ModelRunner.shared.loadModel(
            from: model.localPath,
            contextLength: model.runtimeContextLength,
            gpuLayers: AppSettings.shared.gpuLayers
        )

        return model
    }

    private func streamLegacyGenerate(
        prompt: String,
        systemPrompt: String?,
        model: String,
        parameters: ModelParameters,
        on connection: NWConnection
    ) async {
        sendStreamHeaders(contentType: "application/x-ndjson", on: connection)

        do {
            let result = try await ModelRunner.shared.generate(prompt: prompt, systemPrompt: systemPrompt, parameters: parameters) { [self] token in
                let chunk: [String: Any] = [
                    "model": model,
                    "created_at": self.iso8601String(from: Date()),
                    "response": token,
                    "done": false
                ]
                self.sendNDJSONChunk(data: chunk, on: connection, closeAfterSend: false)
            }

            let finalChunk: [String: Any] = [
                "model": model,
                "created_at": iso8601String(from: Date()),
                "response": "",
                "done": true,
                "total_duration": Int(result.generationTime * 1_000_000_000),
                "load_duration": 0,
                "prompt_eval_count": result.promptTokens,
                "prompt_eval_duration": 0,
                "eval_count": result.tokensGenerated,
                "eval_duration": Int(result.generationTime * 1_000_000_000)
            ]

            sendNDJSONChunk(data: finalChunk, on: connection, closeAfterSend: true)
        } catch {
            let errorChunk: [String: Any] = [
                "error": error.localizedDescription,
                "done": true
            ]
            sendNDJSONChunk(data: errorChunk, on: connection, closeAfterSend: true)
        }
    }

    private func completeLegacyGenerate(
        prompt: String,
        systemPrompt: String?,
        model: String,
        parameters: ModelParameters,
        on connection: NWConnection
    ) async {
        do {
            let result = try await ModelRunner.shared.generate(prompt: prompt, systemPrompt: systemPrompt, parameters: parameters) { _ in }

            sendJSONResponse(
                status: 200,
                body: [
                    "model": model,
                    "created_at": iso8601String(from: Date()),
                    "response": result.text,
                    "done": true,
                    "total_duration": Int(result.generationTime * 1_000_000_000),
                    "load_duration": 0,
                    "prompt_eval_count": result.promptTokens,
                    "prompt_eval_duration": 0,
                    "eval_count": result.tokensGenerated,
                    "eval_duration": Int(result.generationTime * 1_000_000_000)
                ],
                on: connection
            )
        } catch {
            sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection)
        }
    }

    private func streamLegacyChat(
        prompt: String,
        systemPrompt: String?,
        model: String,
        parameters: ModelParameters,
        on connection: NWConnection
    ) async {
        sendStreamHeaders(contentType: "application/x-ndjson", on: connection)

        do {
            let result = try await ModelRunner.shared.generate(prompt: prompt, systemPrompt: systemPrompt, parameters: parameters) { [self] token in
                let chunk: [String: Any] = [
                    "model": model,
                    "created_at": self.iso8601String(from: Date()),
                    "message": [
                        "role": "assistant",
                        "content": token
                    ],
                    "done": false
                ]
                self.sendNDJSONChunk(data: chunk, on: connection, closeAfterSend: false)
            }

            let finalChunk: [String: Any] = [
                "model": model,
                "created_at": iso8601String(from: Date()),
                "message": [
                    "role": "assistant",
                    "content": ""
                ],
                "done": true,
                "total_duration": Int(result.generationTime * 1_000_000_000),
                "load_duration": 0,
                "prompt_eval_count": result.promptTokens,
                "prompt_eval_duration": 0,
                "eval_count": result.tokensGenerated,
                "eval_duration": Int(result.generationTime * 1_000_000_000)
            ]

            sendNDJSONChunk(data: finalChunk, on: connection, closeAfterSend: true)
        } catch {
            let errorChunk: [String: Any] = [
                "error": error.localizedDescription,
                "done": true
            ]
            sendNDJSONChunk(data: errorChunk, on: connection, closeAfterSend: true)
        }
    }

    private func completeLegacyChat(
        prompt: String,
        systemPrompt: String?,
        model: String,
        parameters: ModelParameters,
        on connection: NWConnection
    ) async {
        do {
            let result = try await ModelRunner.shared.generate(prompt: prompt, systemPrompt: systemPrompt, parameters: parameters) { _ in }

            sendJSONResponse(
                status: 200,
                body: [
                    "model": model,
                    "created_at": iso8601String(from: Date()),
                    "message": [
                        "role": "assistant",
                        "content": result.text
                    ],
                    "done": true,
                    "total_duration": Int(result.generationTime * 1_000_000_000),
                    "load_duration": 0,
                    "prompt_eval_count": result.promptTokens,
                    "prompt_eval_duration": 0,
                    "eval_count": result.tokensGenerated,
                    "eval_duration": Int(result.generationTime * 1_000_000_000)
                ],
                on: connection
            )
        } catch {
            sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection)
        }
    }

    private func streamOpenAICompletion(
        requestId: String,
        createdAt: Int,
        model: String,
        prompt: String,
        parameters: ModelParameters,
        on connection: NWConnection
    ) async {
        sendStreamHeaders(on: connection)

        do {
            _ = try await ModelRunner.shared.generate(prompt: prompt, parameters: parameters) { token in
                let chunk: [String: Any] = [
                    "id": requestId,
                    "object": "text_completion",
                    "created": createdAt,
                    "model": model,
                    "choices": [[
                        "text": token,
                        "index": 0,
                        "finish_reason": NSNull()
                    ]]
                ]
                self.sendSSEChunk(data: chunk, on: connection, closeAfterSend: false)
            }

            let finalChunk: [String: Any] = [
                "id": requestId,
                "object": "text_completion",
                "created": createdAt,
                "model": model,
                "choices": [[
                    "text": "",
                    "index": 0,
                    "finish_reason": "stop"
                ]]
            ]
            sendSSEChunk(data: finalChunk, on: connection, closeAfterSend: false)
            sendDoneChunk(on: connection)
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIStreamError(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection)
        }
    }

    private func completeOpenAICompletion(
        requestId: String,
        createdAt: Int,
        model: String,
        prompt: String,
        parameters: ModelParameters,
        on connection: NWConnection
    ) async {
        do {
            let result = try await ModelRunner.shared.generate(prompt: prompt, parameters: parameters) { _ in }
            sendJSONResponse(
                status: 200,
                body: [
                    "id": requestId,
                    "object": "text_completion",
                    "created": createdAt,
                    "model": model,
                    "choices": [[
                        "text": result.text,
                        "index": 0,
                        "finish_reason": "stop"
                    ]],
                    "usage": [
                        "prompt_tokens": result.promptTokens,
                        "completion_tokens": result.tokensGenerated,
                        "total_tokens": result.totalTokens
                    ]
                ],
                on: connection
            )
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection)
        }
    }

    private func streamOpenAIChatCompletion(
        requestId: String,
        createdAt: Int,
        model: String,
        prompt: String,
        systemPrompt: String?,
        parameters: ModelParameters,
        on connection: NWConnection
    ) async {
        sendStreamHeaders(on: connection)

        let roleChunk: [String: Any] = [
            "id": requestId,
            "object": "chat.completion.chunk",
            "created": createdAt,
            "model": model,
            "choices": [[
                "index": 0,
                "delta": ["role": "assistant"],
                "finish_reason": NSNull()
            ]]
        ]
        sendSSEChunk(data: roleChunk, on: connection, closeAfterSend: false)

        do {
            _ = try await ModelRunner.shared.generate(prompt: prompt, systemPrompt: systemPrompt, parameters: parameters) { token in
                let chunk: [String: Any] = [
                    "id": requestId,
                    "object": "chat.completion.chunk",
                    "created": createdAt,
                    "model": model,
                    "choices": [[
                        "index": 0,
                        "delta": ["content": token],
                        "finish_reason": NSNull()
                    ]]
                ]
                self.sendSSEChunk(data: chunk, on: connection, closeAfterSend: false)
            }

            let finalChunk: [String: Any] = [
                "id": requestId,
                "object": "chat.completion.chunk",
                "created": createdAt,
                "model": model,
                "choices": [[
                    "index": 0,
                    "delta": [:],
                    "finish_reason": "stop"
                ]]
            ]
            sendSSEChunk(data: finalChunk, on: connection, closeAfterSend: false)
            sendDoneChunk(on: connection)
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIStreamError(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection)
        }
    }

    private func completeOpenAIChatCompletion(
        requestId: String,
        createdAt: Int,
        model: String,
        prompt: String,
        systemPrompt: String?,
        parameters: ModelParameters,
        on connection: NWConnection
    ) async {
        do {
            let result = try await ModelRunner.shared.generate(prompt: prompt, systemPrompt: systemPrompt, parameters: parameters) { _ in }
            sendJSONResponse(
                status: 200,
                body: [
                    "id": requestId,
                    "object": "chat.completion",
                    "created": createdAt,
                    "model": model,
                    "choices": [[
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": result.text
                        ],
                        "finish_reason": "stop"
                    ]],
                    "usage": [
                        "prompt_tokens": result.promptTokens,
                        "completion_tokens": result.tokensGenerated,
                        "total_tokens": result.totalTokens
                    ]
                ],
                on: connection
            )
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection)
        }
    }

    private func resolvePullModelID(from requestedName: String) async throws -> String {
        if requestedName.contains("/") {
            return requestedName
        }

        let results = try await HuggingFaceService.shared.searchModels(query: requestedName, limit: 10)
        if let exact = results.first(where: { $0.displayName.caseInsensitiveCompare(requestedName) == .orderedSame || $0.modelId.caseInsensitiveCompare(requestedName) == .orderedSame }) {
            return exact.modelId
        }
        if let first = results.first {
            return first.modelId
        }

        throw NSError(domain: "ServerManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Could not resolve a Hugging Face GGUF repository for \(requestedName)."])
    }

    private func selectFile(for requestedFilename: String?, from files: [GGUFInfo]) -> GGUFInfo? {
        guard let requestedFilename, !requestedFilename.isEmpty else {
            return files.first
        }

        return files.first { $0.filename.caseInsensitiveCompare(requestedFilename) == .orderedSame }
    }

    private func legacyModelName(for snapshot: ModelSnapshot) -> String {
        snapshot.apiIdentifier
    }

    private func openAIModelIdentifier(for snapshot: ModelSnapshot) -> String {
        snapshot.apiIdentifier
    }

    private func iso8601String(from date: Date) -> String {
        Self.iso8601FormatterLock.lock()
        defer { Self.iso8601FormatterLock.unlock() }
        return Self.iso8601Formatter.string(from: date)
    }

    private func isInstructionRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role.caseInsensitiveCompare("system") == .orderedSame
            || role.caseInsensitiveCompare("developer") == .orderedSame
    }

    private enum ParameterAPIStyle {
        case ollama
        case openAI
    }

    private func modelParameters(from json: [String: Any], apiStyle: ParameterAPIStyle) -> ModelParameters {
        var parameters = ModelParameters.default

        let parameterSource: [String: Any]
        switch apiStyle {
        case .ollama:
            parameterSource = json["options"] as? [String: Any] ?? json
        case .openAI:
            parameterSource = json
        }

        if let temperature = extractDouble(forKeys: ["temperature"], from: parameterSource) {
            parameters.temperature = temperature
        }

        if let topP = extractDouble(forKeys: ["top_p", "topP"], from: parameterSource) {
            parameters.topP = topP
        }

        if let topK = extractInt(forKeys: ["top_k", "topK"], from: parameterSource) {
            parameters.topK = topK
        }

        if let repeatPenalty = extractDouble(forKeys: ["repeat_penalty", "repeatPenalty"], from: parameterSource) {
            parameters.repeatPenalty = repeatPenalty
        }

        let maxTokenKeys: [String]
        switch apiStyle {
        case .ollama:
            maxTokenKeys = ["num_predict", "numPredict", "max_tokens", "maxTokens"]
        case .openAI:
            maxTokenKeys = ["max_tokens", "maxTokens", "max_completion_tokens", "maxCompletionTokens", "max_output_tokens", "maxOutputTokens"]
        }

        if let maxTokens = extractInt(forKeys: maxTokenKeys, from: parameterSource) {
            parameters.maxTokens = maxTokens
        }

        return parameters
    }

    private func extractDouble(forKeys keys: [String], from json: [String: Any]) -> Double? {
        for key in keys {
            guard let value = json[key] else { continue }

            if let number = value as? NSNumber {
                return number.doubleValue
            }

            if let string = value as? String, let number = Double(string) {
                return number
            }
        }

        return nil
    }

    private func extractInt(forKeys keys: [String], from json: [String: Any]) -> Int? {
        for key in keys {
            guard let value = json[key] else { continue }

            if let number = value as? NSNumber {
                return number.intValue
            }

            if let string = value as? String, let number = Int(string) {
                return number
            }
        }

        return nil
    }

    private func decodeJSONObject(from request: String) -> [String: Any]? {
        guard let body = extractBody(from: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private func extractStringContent(from value: Any?) -> String? {
        if let value = value as? String {
            return value
        }

        if let values = value as? [String] {
            return values.joined(separator: "\n")
        }

        if let parts = value as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                if let text = part["text"] as? String {
                    return text
                }

                if let nestedText = part["input_text"] as? String {
                    return nestedText
                }

                return nil
            }.joined()

            return text.isEmpty ? nil : text
        }

        return nil
    }

    private func sendJSONResponse(status: Int, body: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]) else {
            sendErrorResponse(status: 500, message: "Internal Server Error", on: connection)
            return
        }

        let header = """
        HTTP/1.1 \(status) \(HTTPStatusText(status))
        Content-Type: application/json
        Content-Length: \(data.count)
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Headers: Authorization, Content-Type
        Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS
        Connection: close

        
        """

        connection.send(content: header.data(using: .utf8)! + data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendStreamHeaders(contentType: String = "text/event-stream", on connection: NWConnection) {
        let header = """
        HTTP/1.1 200 OK
        Content-Type: \(contentType)
        Cache-Control: no-cache
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Headers: Authorization, Content-Type
        Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS
        Connection: close

        
        """

        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func sendCORSPreflightResponse(on connection: NWConnection) {
        let header = """
        HTTP/1.1 204 No Content
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Headers: Authorization, Content-Type
        Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS
        Access-Control-Max-Age: 86400
        Content-Length: 0
        Connection: close

        
        """

        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendSSEChunk(data: [String: Any], on connection: NWConnection, closeAfterSend: Bool) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            if closeAfterSend {
                connection.cancel()
            }
            return
        }

        sendRawSSEChunk("data: \(jsonString)\n\n", on: connection, closeAfterSend: closeAfterSend)
    }

    private func sendNDJSONChunk(data: [String: Any], on connection: NWConnection, closeAfterSend: Bool) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            if closeAfterSend {
                connection.cancel()
            }
            return
        }

        sendRawSSEChunk("\(jsonString)\n", on: connection, closeAfterSend: closeAfterSend)
    }

    private func sendDoneChunk(on connection: NWConnection) {
        sendRawSSEChunk("data: [DONE]\n\n", on: connection, closeAfterSend: true)
    }

    private func sendOpenAIStreamError(
        status: Int,
        message: String,
        type: String = "server_error",
        code: String? = nil,
        on connection: NWConnection
    ) {
        let _ = status
        var errorBody: [String: Any] = [
            "message": message,
            "type": type
        ]

        if let code {
            errorBody["code"] = code
        }

        sendSSEChunk(data: ["error": errorBody], on: connection, closeAfterSend: false)
        sendDoneChunk(on: connection)
    }

    private func sendPullError(stream: Bool, status: Int, message: String, on connection: NWConnection) {
        if stream {
            sendStreamHeaders(contentType: "application/x-ndjson", on: connection)
            sendNDJSONChunk(
                data: [
                    "error": message,
                    "status": HTTPStatusText(status).lowercased(),
                    "done": true
                ],
                on: connection,
                closeAfterSend: true
            )
        } else {
            sendErrorResponse(status: status, message: message, on: connection)
        }
    }

    private func sendRawSSEChunk(_ chunk: String, on connection: NWConnection, closeAfterSend: Bool) {
        connection.send(content: chunk.data(using: .utf8), completion: .contentProcessed { _ in
            if closeAfterSend {
                connection.cancel()
            }
        })
    }

    private func sendErrorResponse(status: Int, message: String, on connection: NWConnection) {
        sendJSONResponse(status: status, body: ["error": message], on: connection)
    }

    private func sendOpenAIErrorResponse(
        status: Int,
        message: String,
        type: String = "invalid_request_error",
        code: String? = nil,
        on connection: NWConnection
    ) {
        var errorBody: [String: Any] = [
            "message": message,
            "type": type
        ]

        if let code {
            errorBody["code"] = code
        }

        sendJSONResponse(status: status, body: ["error": errorBody], on: connection)
    }

    private func extractBody(from request: String) -> Data? {
        guard let separatorRange = request.range(of: "\r\n\r\n") else {
            return nil
        }

        let body = request[separatorRange.upperBound...]
        return body.data(using: .utf8)
    }

    private func parseHeaders(from lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]

        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        return headers
    }

    private func requestLengthIfComplete(in data: Data) -> Int? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerEnd = headerRange.upperBound
        let headerData = data.prefix(headerEnd)
        let contentLength = parseContentLength(from: headerData) ?? 0
        let totalLength = headerEnd + contentLength

        guard data.count >= totalLength else {
            return nil
        }

        return totalLength
    }

    private func parseContentLength(from headerData: Data) -> Int? {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        for line in headerString.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            if parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }

        return nil
    }

    private func HTTPStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Unknown"
        }
    }

    private func httpStatus(for error: Error) -> Int {
        let nsError = error as NSError
        switch nsError.code {
        case 400, 401, 403, 404, 501:
            return nsError.code
        default:
            return 500
        }
    }

    private func openAIErrorType(for status: Int) -> String {
        switch status {
        case 401:
            return "authentication_error"
        case 400, 403, 404:
            return "invalid_request_error"
        case 501:
            return "not_implemented_error"
        default:
            return "server_error"
        }
    }
}

struct ModelSnapshot: Sendable {
    let id: UUID
    let name: String
    let modelId: String
    let localPath: String
    let size: Int64
    let downloadDate: Date
    let isDownloaded: Bool
    let quantization: String
    let parameters: String
    let contextLength: Int

    var displayName: String {
        let modelName = modelId.split(separator: "/").last.map(String.init)
        return !name.isEmpty ? name : (modelName ?? modelId)
    }

    var fileExists: Bool {
        !localPath.isEmpty && FileManager.default.fileExists(atPath: localPath)
    }

    var runtimeContextLength: Int {
        max(AppSettings.shared.defaultContextLength, 512)
    }

    var apiIdentifier: String {
        guard let name = name.nonEmpty else {
            return modelId
        }

        return "\(modelId)#\(name)"
    }
}

@MainActor
final class ModelStorage {
    static let shared = ModelStorage()

    private var container: ModelContainer?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    func allSnapshots() -> [ModelSnapshot] {
        guard let container else { return [] }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedModel>(
            sortBy: [SortDescriptor(\DownloadedModel.downloadDate, order: .reverse)]
        )

        let models = (try? context.fetch(descriptor)) ?? []
        return models
            .filter(\.isDownloaded)
            .map(snapshot(from:))
    }

    func snapshot(name: String) -> ModelSnapshot? {
        resolvedSnapshot(for: name, in: allSnapshots())
    }

    func upsertDownloadedModel(_ model: DownloadedModel) {
        guard let container else { return }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedModel>()
        let existingModels = (try? context.fetch(descriptor)) ?? []

        for existing in existingModels where
            existing.modelId.caseInsensitiveCompare(model.modelId) == .orderedSame &&
            existing.name.caseInsensitiveCompare(model.name) == .orderedSame
        {
            if ModelRunner.shared.loadedModelPath == existing.localPath {
                ModelRunner.shared.unloadModel()
            }

            if !existing.localPath.isEmpty && existing.localPath != model.localPath {
                try? FileManager.default.removeItem(atPath: existing.localPath)
            }

            context.delete(existing)
        }

        context.insert(model)
        try? context.save()
    }

    func deleteModel(name: String) -> Bool {
        guard let container else { return false }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedModel>()
        let models = (try? context.fetch(descriptor)) ?? []
        guard let model = resolvedDownloadedModel(for: name, in: models) else {
            return false
        }

        if ModelRunner.shared.loadedModelPath == model.localPath {
            ModelRunner.shared.unloadModel()
        }

        if model.matchesStoredReference(AppSettings.shared.defaultModelId) {
            AppSettings.shared.defaultModelId = ""
        }

        if !model.localPath.isEmpty {
            try? FileManager.default.removeItem(atPath: model.localPath)
        }

        context.delete(model)

        try? context.save()
        return true
    }

    private func resolvedSnapshot(for candidate: String, in snapshots: [ModelSnapshot]) -> ModelSnapshot? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else { return nil }

        return snapshots
            .compactMap { snapshot in
                matchPriority(for: normalizedCandidate, snapshot: snapshot).map { ($0, snapshot) }
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return lhs.0 < rhs.0
                }

                if lhs.1.downloadDate != rhs.1.downloadDate {
                    return lhs.1.downloadDate > rhs.1.downloadDate
                }

                return lhs.1.id.uuidString < rhs.1.id.uuidString
            }
            .first?
            .1
    }

    private func resolvedDownloadedModel(for candidate: String, in models: [DownloadedModel]) -> DownloadedModel? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else { return nil }

        return models
            .compactMap { model in
                matchPriority(for: normalizedCandidate, model: model).map { ($0, model) }
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return lhs.0 < rhs.0
                }

                if lhs.1.downloadDate != rhs.1.downloadDate {
                    return lhs.1.downloadDate > rhs.1.downloadDate
                }

                return lhs.1.id.uuidString < rhs.1.id.uuidString
            }
            .first?
            .1
    }

    private func matchPriority(for candidate: String, snapshot: ModelSnapshot) -> Int? {
        if snapshot.localPath.caseInsensitiveCompare(candidate) == .orderedSame {
            return 0
        }

        if snapshot.apiIdentifier.caseInsensitiveCompare(candidate) == .orderedSame {
            return 1
        }

        if snapshot.modelId.caseInsensitiveCompare(candidate) == .orderedSame {
            return 2
        }

        if snapshot.name.caseInsensitiveCompare(candidate) == .orderedSame {
            return 3
        }

        if snapshot.displayName.caseInsensitiveCompare(candidate) == .orderedSame {
            return 4
        }

        return nil
    }

    private func matchPriority(for candidate: String, model: DownloadedModel) -> Int? {
        if model.localPath.caseInsensitiveCompare(candidate) == .orderedSame {
            return 0
        }

        if model.apiIdentifier.caseInsensitiveCompare(candidate) == .orderedSame {
            return 1
        }

        if model.modelId.caseInsensitiveCompare(candidate) == .orderedSame {
            return 2
        }

        if model.name.caseInsensitiveCompare(candidate) == .orderedSame {
            return 3
        }

        if model.displayName.caseInsensitiveCompare(candidate) == .orderedSame {
            return 4
        }

        return nil
    }

    private func snapshot(from model: DownloadedModel) -> ModelSnapshot {
        ModelSnapshot(
            id: model.id,
            name: model.name,
            modelId: model.modelId,
            localPath: model.localPath,
            size: model.size,
            downloadDate: model.downloadDate,
            isDownloaded: model.isDownloaded,
            quantization: model.quantization,
            parameters: model.parameters,
            contextLength: model.contextLength
        )
    }
}
