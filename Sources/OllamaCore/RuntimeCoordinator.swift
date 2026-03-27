import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public actor RuntimeCoordinator {
    public static let shared = RuntimeCoordinator()

    private let registry = ModelRegistryStore.shared
    private let capabilityService = DeviceCapabilityService.shared
    private let ggufBackend = GGUFBackend()
    private let appleBackend = AppleFoundationBackend()
    private let coreMLBackend = CoreMLPackageBackend()

    private var activeCatalogIdValue: String?
    private var activeBackendKind: ModelBackendKind?

    public func availableEntries(contextLength: Int = 4096) async throws -> [ModelCatalogEntry] {
        try await registry.allEntries(includeBuiltIn: true, contextLength: contextLength)
    }

    public func installedEntries() async throws -> [ModelCatalogEntry] {
        try await registry.installedEntries()
    }

    public func resolveModelReference(_ reference: String, contextLength: Int = 4096) async throws -> ModelCatalogEntry? {
        try await registry.resolve(reference: reference, contextLength: contextLength)
    }

    public func activeCatalogId() -> String? {
        activeCatalogIdValue
    }

    public func activeEntry(contextLength: Int = 4096) async throws -> ModelCatalogEntry? {
        guard let activeCatalogIdValue else { return nil }
        return try await registry.resolve(reference: activeCatalogIdValue, contextLength: contextLength)
    }

    @discardableResult
    public func loadModel(catalogId: String, runtime: RuntimePreferences) async throws -> ModelCatalogEntry {
        guard let entry = try await registry.resolve(reference: catalogId, contextLength: runtime.contextLength) else {
            throw InferenceError.registryFailure("The selected model could not be found in the registry.")
        }

        let compatibility = await capabilityService.compatibility(for: entry)
        guard compatibility.isUsable else {
            throw InferenceError.compatibilityFailure(compatibility.message)
        }

        await unloadInactiveBackends(keeping: entry.backendKind)
        try await backend(for: entry.backendKind).load(entry: entry, runtime: runtime)
        activeCatalogIdValue = entry.catalogId
        activeBackendKind = entry.backendKind
        return entry
    }

    public func unloadModel() async {
        await ggufBackend.unload()
        await appleBackend.unload()
        await coreMLBackend.unload()
        activeCatalogIdValue = nil
        activeBackendKind = nil
    }

    public func stopGeneration() async {
        await ggufBackend.stopGeneration()
        await appleBackend.stopGeneration()
        await coreMLBackend.stopGeneration()
    }

    public func generate(
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult {
        let entry = try await loadModel(catalogId: request.catalogId, runtime: request.runtimePreferences)
        let result = try await backend(for: entry.backendKind).generate(
            entry: entry,
            request: request,
            onChunk: onChunk
        )
        activeCatalogIdValue = entry.catalogId
        activeBackendKind = entry.backendKind
        return result
    }

    private func unloadInactiveBackends(keeping backendKind: ModelBackendKind) async {
        if backendKind != .ggufLlama {
            await ggufBackend.unload()
        }
        if backendKind != .appleFoundation {
            await appleBackend.unload()
        }
        if backendKind != .coreMLPackage {
            await coreMLBackend.unload()
        }
    }

    private func backend(for kind: ModelBackendKind) -> InferenceBackend {
        switch kind {
        case .ggufLlama:
            return ggufBackend
        case .appleFoundation:
            return appleBackend
        case .coreMLPackage:
            return coreMLBackend
        }
    }
}

final class AppleFoundationBackend: InferenceBackend {
    let kind: ModelBackendKind = .appleFoundation

    var activeCatalogId: String? {
        stateLock.withLock { _activeCatalogId }
    }

    private let stateLock = NSLock()
    private var activeTask: Task<InferenceResult, Error>?
    private var activeRequestID = UUID()
    private var _activeCatalogId: String?

    func load(entry: ModelCatalogEntry, runtime: RuntimePreferences) async throws {
        let _ = runtime
        stateLock.withLock {
            _activeCatalogId = entry.catalogId
        }
    }

    func unload() async {
        await stopGeneration()
        stateLock.withLock {
            _activeCatalogId = nil
        }
    }

    func generate(
        entry: ModelCatalogEntry,
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult {
        let _ = onChunk
        stateLock.withLock {
            _activeCatalogId = entry.catalogId
        }

        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            throw InferenceError.appleModelUnavailable("Apple's on-device model requires iOS 26 or newer.")
        }

        await stopGeneration()

        let requestID = UUID()
        activeRequestID = requestID

        let normalizedPrompt = request.prompt.trimmedForLookup
        let instructions = request.systemPrompt?.trimmedForLookup.nonEmpty

        let task = Task<InferenceResult, Error> {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let session: LanguageModelSession
            if let instructions {
                session = LanguageModelSession(instructions: instructions)
            } else {
                session = LanguageModelSession()
            }

            let response = try await session.respond(to: normalizedPrompt)
            try Task.checkCancellation()

            let elapsed = max(CFAbsoluteTimeGetCurrent() - startedAt, 0.001)
            return InferenceResult(
                text: response.content.trimmedForLookup,
                tokensGenerated: 0,
                promptTokens: 0,
                generationTime: elapsed,
                tokensPerSecond: 0,
                wasCancelled: false
            )
        }

        activeTask = task

        do {
            let result = try await task.value
            if activeRequestID == requestID {
                activeTask = nil
            }
            return result
        } catch is CancellationError {
            if activeRequestID == requestID {
                activeTask = nil
            }
            throw InferenceError.generationCancelled
        } catch {
            if activeRequestID == requestID {
                activeTask = nil
            }
            throw error
        }
        #else
        throw InferenceError.appleModelUnavailable("This build does not include Apple's on-device model.")
        #endif
    }

    func stopGeneration() async {
        activeRequestID = UUID()
        activeTask?.cancel()
        activeTask = nil
    }
}

final class CoreMLPackageBackend: InferenceBackend {
    let kind: ModelBackendKind = .coreMLPackage

    var activeCatalogId: String? {
        stateLock.withLock { _activeCatalogId }
    }

    private let stateLock = NSLock()
    private var _activeCatalogId: String?

    func load(entry: ModelCatalogEntry, runtime: RuntimePreferences) async throws {
        let _ = runtime
        guard let packageRootPath = entry.packageRootPath?.trimmedForLookup, !packageRootPath.isEmpty else {
            throw InferenceError.backendUnavailable("This CoreML package is missing its package root.")
        }

        guard FileManager.default.fileExists(atPath: packageRootPath) else {
            throw InferenceError.backendUnavailable("This CoreML package no longer exists on disk.")
        }

        stateLock.withLock {
            _activeCatalogId = entry.catalogId
        }
    }

    func unload() async {
        stateLock.withLock {
            _activeCatalogId = nil
        }
    }

    func generate(
        entry: ModelCatalogEntry,
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult {
        let _ = entry
        let _ = request
        let _ = onChunk
        throw InferenceError.unsupportedBackend("CoreML package execution is not available in this build yet. The package can be imported, inspected, and selected, but it cannot generate text until an ANEMLL-compatible runtime adapter is added.")
    }

    func stopGeneration() async {}
}
