import Foundation
import llama

actor ModelRunner {
    static let shared = ModelRunner()
    
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var batch: llama_batch?
    private var isModelLoaded = false
    private var currentModelPath: String?
    private var sampler: OpaquePointer?
    
    private var contextLength: Int = 4096
    private var batchSize: Int = 512
    
    private var generationTask: Task<Void, Never>?
    private var shouldStopGeneration = false
    
    private init() {
        // Initialize llama backend
        llama_backend_init()
        llama_numa_init(GGML_NUMA_STRATEGY_DISABLED)
    }
    
    deinit {
        unloadModel()
        llama_backend_free()
    }
    
    func loadModel(from path: String, contextLength: Int = 4096, gpuLayers: Int = 0) async throws {
        // Validate path is not empty
        guard !path.isEmpty else {
            throw ModelError.invalidPath
        }
        
        // Validate file exists at the given path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ModelError.modelNotFound
        }
        
        // Unload any existing model
        unloadModel()
        
        self.contextLength = contextLength
        
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Int32(gpuLayers)
        modelParams.use_mlock = AppSettings.shared.mlockEnabled
        modelParams.use_mmap = AppSettings.shared.mmapEnabled
        
        guard let newModel = llama_load_model_from_file(path, modelParams) else {
            throw ModelError.failedToLoadModel
        }
        
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextLength)
        ctxParams.n_batch = UInt32(AppSettings.shared.batchSize)
        ctxParams.n_threads = UInt32(AppSettings.shared.threads)
        ctxParams.n_threads_batch = UInt32(AppSettings.shared.threads)
        ctxParams.flash_attn = AppSettings.shared.flashAttentionEnabled
        
        guard let newCtx = llama_new_context_with_model(newModel, ctxParams) else {
            llama_free_model(newModel)
            throw ModelError.failedToCreateContext
        }
        
        self.model = newModel
        self.ctx = newCtx
        self.currentModelPath = path
        self.isModelLoaded = true
        
        // Initialize sampler
        setupSampler()
        
        // Initialize batch
        batch = llama_batch_init(Int32(AppSettings.shared.batchSize), 0, 1)
    }
    
    private func setupSampler() {
        let settings = AppSettings.shared
        
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        
        // Add temperature sampling
        if settings.defaultTemperature > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(settings.defaultTemperature)))
        }
        
        // Add top-k sampling
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(settings.defaultTopK)))
        
        // Add top-p sampling
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(Float(settings.defaultTopP), 1))
        
        // Add repetition penalty
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
            Int32(settings.defaultContextLength),
            Int32(settings.defaultRepeatLastN),
            Float(settings.defaultRepeatPenalty),
            0.0,
            0.0
        ))
        
        // Add greedy sampler for final selection
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
    }
    
    func unloadModel() {
        generationTask?.cancel()
        
        if let batch = batch {
            llama_batch_free(batch)
            self.batch = nil
        }
        
        if let sampler = sampler {
            llama_sampler_free(sampler)
            self.sampler = nil
        }
        
        if let ctx = ctx {
            llama_free(ctx)
            self.ctx = nil
        }
        
        if let model = model {
            llama_free_model(model)
            self.model = nil
        }
        
        isModelLoaded = false
        currentModelPath = nil
    }
    
    func generate(
        prompt: String,
        systemPrompt: String? = nil,
        parameters: ModelParameters = .default,
        onToken: @escaping (String) -> Void
    ) async throws -> GenerationResult {
        guard isModelLoaded, let ctx = ctx, let model = model, let batch = batch else {
            throw ModelError.noModelLoaded
        }
        
        shouldStopGeneration = false
        
        let fullPrompt = formatPrompt(userPrompt: prompt, systemPrompt: systemPrompt)
        
        let tokens = try tokenize(fullPrompt)
        let promptTokens = tokens.count
        
        // Clear previous kv cache
        llama_kv_cache_clear(ctx)
        
        // Process prompt in batches
        var nCur = 0
        let nPromptTokens = tokens.count
        
        for i in stride(from: 0, to: nPromptTokens, by: batchSize) {
            let batchEnd = min(i + batchSize, nPromptTokens)
            let batchTokens = Array(tokens[i..<batchEnd])
            let nTokens = batchTokens.count
            
            batch.n_tokens = Int32(nTokens)
            for (j, token) in batchTokens.enumerated() {
                batch.token[j] = token
                batch.pos[j] = Int32(nCur + j)
                batch.n_seq_id[j] = 1
                batch.seq_id[j][0] = 0
                batch.logits[j] = 0
            }
            batch.logits[nTokens - 1] = 1
            
            if llama_decode(ctx, batch) != 0 {
                throw ModelError.decodeError
            }
            
            nCur += nTokens
        }
        
        // Generate response tokens
        var response = ""
        var nGen = 0
        let maxTokens = parameters.maxTokens > 0 ? parameters.maxTokens : contextLength - promptTokens
        let startTime = CFAbsoluteTimeGetCurrent()
        
        while nGen < maxTokens && !shouldStopGeneration {
            var newTokenId: llama_token = 0
            
            // Sample next token
            if let sampler = sampler {
                newTokenId = llama_sampler_sample(sampler, ctx, Int32(nCur - 1))
            } else {
                newTokenId = llama_sampler_sample(llama_sampler_init_greedy(), ctx, Int32(nCur - 1))
            }
            
            // Check for end of generation
            if llama_token_is_eog(model, newTokenId) {
                break
            }
            
            // Detokenize
            if let piece = detokenize([newTokenId]) {
                response += piece
                onToken(piece)
            }
            
            // Prepare next batch with single token
            llama_batch_clear(batch)
            llama_batch_add(batch, newTokenId, Int32(nCur), [0], true)
            
            if llama_decode(ctx, batch) != 0 {
                throw ModelError.decodeError
            }
            
            nCur += 1
            nGen += 1
            
            // Check context limit
            if nCur >= contextLength {
                break
            }
        }
        
        let generationTime = CFAbsoluteTimeGetCurrent() - startTime
        let tokensPerSecond = Double(nGen) / generationTime
        
        return GenerationResult(
            text: response,
            tokensGenerated: nGen,
            promptTokens: promptTokens,
            generationTime: generationTime,
            tokensPerSecond: tokensPerSecond
        )
    }
    
    func stopGeneration() {
        shouldStopGeneration = true
        generationTask?.cancel()
    }
    
    private func tokenize(_ text: String) throws -> [llama_token] {
        guard let model = model else {
            throw ModelError.noModelLoaded
        }
        
        let nTokens = Int(llama_tokenize(model, text, Int32(text.utf8.count), nil, 0, true, true))
        guard nTokens > 0 else {
            return []
        }
        
        var tokens = [llama_token](repeating: 0, count: nTokens)
        llama_tokenize(model, text, Int32(text.utf8.count), &tokens, Int32(nTokens), true, true)
        
        return tokens
    }
    
    private func detokenize(_ tokens: [llama_token]) -> String? {
        guard let model = model else { return nil }
        
        var result = ""
        for token in tokens {
            var buf = [CChar](repeating: 0, count: 32)
            let n = llama_token_to_piece(model, token, &buf, Int32(buf.count), 0, true)
            if n > 0 {
                let piece = String(cString: buf)
                result += piece
            }
        }
        return result.isEmpty ? nil : result
    }
    
    private func formatPrompt(userPrompt: String, systemPrompt: String?) -> String {
        let system = systemPrompt ?? "You are a helpful assistant."
        return "<|system|>\n\(system)</s>\n<|user|>\n\(userPrompt)</s>\n<|assistant|>\n"
    }
    
    var isLoaded: Bool {
        isModelLoaded
    }
    
    var loadedModelPath: String? {
        currentModelPath
    }
}

struct GenerationResult {
    let text: String
    let tokensGenerated: Int
    let promptTokens: Int
    let generationTime: Double
    let tokensPerSecond: Double
    
    var totalTokens: Int {
        tokensGenerated + promptTokens
    }
}

enum ModelError: Error, LocalizedError {
    case modelNotFound
    case invalidPath
    case failedToLoadModel
    case failedToCreateContext
    case noModelLoaded
    case tokenizationError
    case decodeError
    case generationCancelled
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Model file not found at the stored path. The app may have been moved or the model needs to be re-downloaded."
        case .invalidPath:
            return "Invalid model path. Please re-download the model."
        case .failedToLoadModel:
            return "Failed to load model"
        case .failedToCreateContext:
            return "Failed to create context"
        case .noModelLoaded:
            return "No model is currently loaded"
        case .tokenizationError:
            return "Tokenization error"
        case .decodeError:
            return "Decode error"
        case .generationCancelled:
            return "Generation was cancelled"
        }
    }
}
