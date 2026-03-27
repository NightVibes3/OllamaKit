import Foundation
import Combine

#if canImport(llama)
import llama
#endif

final class ModelRunner: ObservableObject {
    static let shared = ModelRunner()

    @Published private(set) var activeLoadedModelPath: String?

    private let queue = DispatchQueue(label: "com.ollamakit.modelrunner", qos: .userInitiated)
    private let stateLock = NSLock()

    private var backend: BackendEngine?
    private var selectedContextLength = 4096
    private var selectedGPULayers = 0
    private var autoOffloadTask: Task<Void, Never>?
    private var cancelRequested = false

    private var _isLoaded = false
    private var _loadedModelPath: String?

    var isLoaded: Bool {
        stateLock.withLock { _isLoaded }
    }

    var loadedModelPath: String? {
        stateLock.withLock { _loadedModelPath }
    }

    private init() {}

    func loadModel(from path: String, contextLength: Int = 4096, gpuLayers: Int = 0) async throws {
        guard !path.isEmpty else {
            throw ModelError.invalidPath
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw ModelError.modelNotFound
        }

        cancelAutoOffload()

        let configuration = BackendConfiguration(
            modelPath: path,
            contextLength: max(contextLength, 512),
            gpuLayers: max(gpuLayers, 0),
            threads: max(AppSettings.shared.threads, 1),
            batchSize: max(AppSettings.shared.batchSize, 32),
            flashAttentionEnabled: AppSettings.shared.flashAttentionEnabled,
            mmapEnabled: AppSettings.shared.mmapEnabled,
            mlockEnabled: AppSettings.shared.mlockEnabled
        )

        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if let backend = self.backend, backend.matches(configuration) {
                        self.selectedContextLength = configuration.contextLength
                        self.selectedGPULayers = configuration.gpuLayers
                        self.setCancelRequested(false)
                        self.stateLock.withLock {
                            self._loadedModelPath = path
                            self._isLoaded = true
                        }
                        self.publishLoadedModelPath(path)
                        continuation.resume()
                        return
                    }

                    self.setCancelRequested(true)
                    self.backend = nil

                    let backend = try BackendEngine(configuration: configuration)
                    self.backend = backend
                    self.selectedContextLength = configuration.contextLength
                    self.selectedGPULayers = configuration.gpuLayers
                    self.setCancelRequested(false)

                    self.stateLock.withLock {
                        self._loadedModelPath = path
                        self._isLoaded = true
                    }
                    self.publishLoadedModelPath(path)

                    continuation.resume()
                } catch {
                    self.backend = nil
                    self.setCancelRequested(false)
                    self.stateLock.withLock {
                        self._loadedModelPath = nil
                        self._isLoaded = false
                    }
                    self.publishLoadedModelPath(nil)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func unloadModel() {
        cancelAutoOffload()
        stateLock.withLock {
            _loadedModelPath = nil
            _isLoaded = false
        }
        publishLoadedModelPath(nil)

        queue.async {
            self.setCancelRequested(true)
            self.backend = nil
        }
    }

    func generate(
        prompt: String,
        systemPrompt: String? = nil,
        parameters: ModelParameters = .default,
        onToken: @escaping (String) -> Void
    ) async throws -> GenerationResult {
        guard isLoaded else {
            throw ModelError.noModelLoaded
        }

        cancelAutoOffload()

        let effectivePrompt = buildEffectivePrompt(prompt: prompt, systemPrompt: systemPrompt)

        let result = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let backend = self.backend else {
                    continuation.resume(throwing: ModelError.noModelLoaded)
                    return
                }

                self.setCancelRequested(false)

                do {
                    let result = try backend.generate(
                        prompt: effectivePrompt,
                        parameters: parameters,
                        shouldCancel: { [weak self] in
                            self?.isCancellationRequested ?? true
                        },
                        onToken: onToken
                    )

                    self.setCancelRequested(false)
                    continuation.resume(returning: result)
                } catch {
                    self.setCancelRequested(false)
                    continuation.resume(throwing: error)
                }
            }
        }

        scheduleAutoOffloadIfNeeded()
        return result
    }

    func stopGeneration() {
        setCancelRequested(true)
        scheduleAutoOffloadIfNeeded()
    }

    private func buildEffectivePrompt(prompt: String, systemPrompt: String?) -> String {
        [systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), prompt.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")
    }

    private func cancelAutoOffload() {
        autoOffloadTask?.cancel()
        autoOffloadTask = nil
    }

    private var isCancellationRequested: Bool {
        stateLock.withLock { cancelRequested }
    }

    private func setCancelRequested(_ value: Bool) {
        stateLock.withLock {
            cancelRequested = value
        }
    }

    private func publishLoadedModelPath(_ path: String?) {
        Task { @MainActor in
            self.activeLoadedModelPath = path
        }
    }

    private func scheduleAutoOffloadIfNeeded() {
        cancelAutoOffload()

        guard isLoaded, !AppSettings.shared.keepModelInMemory else { return }

        let delayMinutes = max(AppSettings.shared.autoOffloadMinutes, 1)
        autoOffloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delayMinutes * 60))
                guard !Task.isCancelled else { return }
                self?.unloadModel()
            } catch {
                return
            }
        }
    }
}

struct GenerationResult {
    let text: String
    let tokensGenerated: Int
    let promptTokens: Int
    let generationTime: Double
    let tokensPerSecond: Double
    let wasCancelled: Bool

    var totalTokens: Int {
        tokensGenerated + promptTokens
    }
}

enum ModelError: Error, LocalizedError {
    case modelNotFound
    case invalidPath
    case failedToLoadModel
    case failedToCreateContext
    case failedToInitializeBackend
    case noModelLoaded
    case tokenizationError
    case decodeError
    case generationCancelled

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Model file not found at the stored path. Please re-download the model."
        case .invalidPath:
            return "Invalid model path. Please re-download the model."
        case .failedToLoadModel:
            return "Failed to load the GGUF model with llama.cpp."
        case .failedToCreateContext:
            return "Failed to create the llama.cpp inference context."
        case .failedToInitializeBackend:
            return "Failed to initialize the llama.cpp backend."
        case .noModelLoaded:
            return "No model is currently loaded."
        case .tokenizationError:
            return "Failed to tokenize the prompt for inference."
        case .decodeError:
            return "Model decoding failed."
        case .generationCancelled:
            return "Generation was cancelled."
        }
    }
}

private struct BackendConfiguration: Equatable {
    let modelPath: String
    let contextLength: Int
    let gpuLayers: Int
    let threads: Int
    let batchSize: Int
    let flashAttentionEnabled: Bool
    let mmapEnabled: Bool
    let mlockEnabled: Bool
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

#if canImport(llama)
private final class BackendEngine {
    private static let backendInitLock = NSLock()
    private static var backendInitialized = false

    private let configuration: BackendConfiguration
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let batchCapacity: Int32
    private var batch: llama_batch
    private var invalidUTF8Buffer: [CChar] = []

    init(configuration: BackendConfiguration) throws {
        self.configuration = configuration

        try Self.initializeBackendIfNeeded()

        var modelParams = llama_model_default_params()

        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = Int32(configuration.gpuLayers)
        #endif

        modelParams.use_mmap = configuration.mmapEnabled
        modelParams.use_mlock = configuration.mlockEnabled
        modelParams.check_tensors = false

        guard let loadedModel = llama_model_load_from_file(configuration.modelPath, modelParams) else {
            throw ModelError.failedToLoadModel
        }

        var contextParams = llama_context_default_params()
        let normalizedBatchSize = min(max(configuration.batchSize, 32), configuration.contextLength)

        contextParams.n_ctx = UInt32(configuration.contextLength)
        contextParams.n_batch = UInt32(normalizedBatchSize)
        contextParams.n_ubatch = UInt32(normalizedBatchSize)
        contextParams.n_seq_max = 1
        contextParams.n_threads = Int32(configuration.threads)
        contextParams.n_threads_batch = Int32(configuration.threads)
        contextParams.flash_attn_type = configuration.flashAttentionEnabled ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED
        contextParams.no_perf = false

        #if targetEnvironment(simulator)
        contextParams.offload_kqv = false
        contextParams.op_offload = false
        #else
        let shouldOffload = configuration.gpuLayers > 0
        contextParams.offload_kqv = shouldOffload
        contextParams.op_offload = shouldOffload
        #endif

        guard let createdContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw ModelError.failedToCreateContext
        }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(createdContext)
            llama_model_free(loadedModel)
            throw ModelError.failedToLoadModel
        }

        self.model = loadedModel
        self.context = createdContext
        self.vocab = loadedVocab
        self.batchCapacity = Int32(normalizedBatchSize)
        self.batch = llama_batch_init(self.batchCapacity, 0, 1)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    func matches(_ configuration: BackendConfiguration) -> Bool {
        self.configuration == configuration
    }

    func generate(
        prompt: String,
        parameters: ModelParameters,
        shouldCancel: () -> Bool,
        onToken: (String) -> Void
    ) throws -> GenerationResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        llama_memory_clear(llama_get_memory(context), true)
        invalidUTF8Buffer.removeAll(keepingCapacity: true)

        let promptTokens = try tokenize(prompt)
        guard !promptTokens.isEmpty else {
            throw ModelError.tokenizationError
        }

        let boundedPromptTokens = truncatePromptTokensIfNeeded(promptTokens)
        try decodePromptTokens(boundedPromptTokens)

        let sampler = makeSampler(parameters: parameters)
        defer { llama_sampler_free(sampler) }

        var generatedText = ""
        var generatedTokenCount = 0
        var currentPosition = Int32(boundedPromptTokens.count)
        var wasCancelled = false
        let maxNewTokens = normalizedMaxNewTokens(promptTokens: boundedPromptTokens.count, requestedMaxTokens: parameters.maxTokens)

        while generatedTokenCount < maxNewTokens {
            if shouldCancel() {
                wasCancelled = true
                break
            }

            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, token) {
                break
            }

            llama_sampler_accept(sampler, token)

            let piece = tokenToPiece(token)
            if !piece.isEmpty {
                generatedText += piece
                onToken(piece)
            }

            llamaBatchClear(&batch)
            llamaBatchAdd(&batch, token, currentPosition, [0], true)
            currentPosition += 1

            if llama_decode(context, batch) != 0 {
                throw ModelError.decodeError
            }

            generatedTokenCount += 1
        }

        llama_synchronize(context)
        let elapsed = max(CFAbsoluteTimeGetCurrent() - startedAt, 0.001)

        return GenerationResult(
            text: generatedText,
            tokensGenerated: generatedTokenCount,
            promptTokens: boundedPromptTokens.count,
            generationTime: elapsed,
            tokensPerSecond: Double(max(generatedTokenCount, 1)) / elapsed,
            wasCancelled: wasCancelled
        )
    }

    private static func initializeBackendIfNeeded() throws {
        try backendInitLock.withLock {
            guard !backendInitialized else { return }
            llama_backend_init()
            backendInitialized = true
        }
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        let addSpecial = llama_vocab_get_add_bos(vocab)
        let maxTokenCount = max(utf8Count + 8, configuration.contextLength + 8)
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: maxTokenCount)
        defer { tokens.deallocate() }

        let tokenCount = llama_tokenize(
            vocab,
            text,
            Int32(utf8Count),
            tokens,
            Int32(maxTokenCount),
            addSpecial,
            false
        )

        guard tokenCount > 0 else {
            throw ModelError.tokenizationError
        }

        return Array(UnsafeBufferPointer(start: tokens, count: Int(tokenCount)))
    }

    private func truncatePromptTokensIfNeeded(_ tokens: [llama_token]) -> [llama_token] {
        let reservedForGeneration = max(min(configuration.contextLength / 8, 512), 64)
        let availablePromptSlots = max(configuration.contextLength - reservedForGeneration, 1)

        guard tokens.count > availablePromptSlots else { return tokens }
        return Array(tokens.suffix(availablePromptSlots))
    }

    private func decodePromptTokens(_ tokens: [llama_token]) throws {
        var startIndex = 0

        while startIndex < tokens.count {
            let endIndex = min(startIndex + Int(batchCapacity), tokens.count)
            let chunk = tokens[startIndex..<endIndex]

            llamaBatchClear(&batch)

            for (offset, token) in chunk.enumerated() {
                let absoluteIndex = startIndex + offset
                let shouldEmitLogits = absoluteIndex == tokens.count - 1
                llamaBatchAdd(&batch, token, Int32(absoluteIndex), [0], shouldEmitLogits)
            }

            if llama_decode(context, batch) != 0 {
                throw ModelError.decodeError
            }

            startIndex = endIndex
        }
    }

    private func normalizedMaxNewTokens(promptTokens: Int, requestedMaxTokens: Int) -> Int {
        let remainingContext = max(configuration.contextLength - promptTokens, 1)

        if requestedMaxTokens > 0 {
            return min(requestedMaxTokens, remainingContext)
        }

        return remainingContext
    }

    private func makeSampler(parameters: ModelParameters) -> UnsafeMutablePointer<llama_sampler> {
        let samplerParams = llama_sampler_chain_default_params()
        let sampler = llama_sampler_chain_init(samplerParams)

        llama_sampler_chain_add(
            sampler,
            llama_sampler_init_penalties(
                Int32(max(AppSettings.shared.defaultRepeatLastN, 0)),
                Float(parameters.repeatPenalty),
                0,
                0
            )
        )

        if parameters.topK > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(parameters.topK)))
        }

        if parameters.topP > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(Float(parameters.topP), 1))
        }

        if parameters.temperature <= 0.0001 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(parameters.temperature)))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        }

        return sampler
    }

    private func tokenToPiece(_ token: llama_token) -> String {
        let tokenBytes = tokenToPieceBytes(token)
        invalidUTF8Buffer.append(contentsOf: tokenBytes)

        if let string = String(validatingUTF8: invalidUTF8Buffer + [0]) {
            invalidUTF8Buffer.removeAll(keepingCapacity: true)
            return string
        }

        if (0..<invalidUTF8Buffer.count).contains(where: { suffixLength in
            guard suffixLength > 0 else { return false }
            return String(validatingUTF8: Array(invalidUTF8Buffer.suffix(suffixLength)) + [0]) != nil
        }) {
            let string = String(cString: invalidUTF8Buffer + [0])
            invalidUTF8Buffer.removeAll(keepingCapacity: true)
            return string
        }

        return ""
    }

    private func tokenToPieceBytes(_ token: llama_token) -> [CChar] {
        let initialCapacity = 16
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: initialCapacity)
        buffer.initialize(repeating: 0, count: initialCapacity)
        defer { buffer.deallocate() }

        let count = llama_token_to_piece(vocab, token, buffer, Int32(initialCapacity), 0, false)

        if count < 0 {
            let largerCapacity = Int(-count)
            let largerBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: largerCapacity)
            largerBuffer.initialize(repeating: 0, count: largerCapacity)
            defer { largerBuffer.deallocate() }

            let resolvedCount = llama_token_to_piece(vocab, token, largerBuffer, Int32(largerCapacity), 0, false)
            return Array(UnsafeBufferPointer(start: largerBuffer, count: Int(resolvedCount)))
        }

        return Array(UnsafeBufferPointer(start: buffer, count: Int(count)))
    }
}

private func llamaBatchClear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llamaBatchAdd(
    _ batch: inout llama_batch,
    _ token: llama_token,
    _ position: llama_pos,
    _ sequenceIDs: [llama_seq_id],
    _ emitLogits: Bool
) {
    let index = Int(batch.n_tokens)
    batch.token[index] = token
    batch.pos[index] = position
    batch.n_seq_id[index] = Int32(sequenceIDs.count)

    for (offset, sequenceID) in sequenceIDs.enumerated() {
        batch.seq_id[index]?[offset] = sequenceID
    }

    batch.logits[index] = emitLogits ? 1 : 0
    batch.n_tokens += 1
}
#else
private final class BackendEngine {
    private let configuration: BackendConfiguration

    init(configuration: BackendConfiguration) throws {
        self.configuration = configuration
        throw ModelError.failedToInitializeBackend
    }

    func matches(_ configuration: BackendConfiguration) -> Bool {
        self.configuration == configuration
    }

    func generate(
        prompt: String,
        parameters: ModelParameters,
        shouldCancel: () -> Bool,
        onToken: (String) -> Void
    ) throws -> GenerationResult {
        let _ = shouldCancel
        let _ = onToken
        throw ModelError.failedToInitializeBackend
    }
}
#endif
