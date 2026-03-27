import Foundation

#if canImport(UIKit)
import UIKit
#endif

public enum ModelBackendKind: String, Codable, CaseIterable, Sendable {
    case ggufLlama = "gguf_llama"
    case coreMLPackage = "coreml_package"
    case appleFoundation = "apple_foundation"
}

public enum ModelImportSource: String, Codable, CaseIterable, Sendable {
    case builtIn
    case huggingFaceDownload
    case localImport
    case coreMLImport
    case migratedLegacy
}

public enum ModelCompatibilityLevel: String, Codable, CaseIterable, Sendable {
    case recommended
    case supported
    case unavailable
    case unknown

    public var isUsable: Bool {
        switch self {
        case .recommended, .supported:
            return true
        case .unavailable, .unknown:
            return false
        }
    }
}

public struct ModelCapabilitySummary: Codable, Hashable, Sendable {
    public var sizeBytes: Int64
    public var quantization: String
    public var parameterCountLabel: String
    public var contextLength: Int
    public var supportsStreaming: Bool
    public var notes: String?

    public init(
        sizeBytes: Int64 = 0,
        quantization: String = "Unknown",
        parameterCountLabel: String = "Unknown",
        contextLength: Int = 4096,
        supportsStreaming: Bool = true,
        notes: String? = nil
    ) {
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.parameterCountLabel = parameterCountLabel
        self.contextLength = contextLength
        self.supportsStreaming = supportsStreaming
        self.notes = notes
    }
}

public struct ModelPackageFile: Codable, Hashable, Sendable {
    public let path: String
    public let sha256: String
    public let sizeBytes: Int64?

    public init(path: String, sha256: String, sizeBytes: Int64?) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

public struct ModelPackageManifest: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var modelId: String
    public var displayName: String
    public var backendKind: ModelBackendKind
    public var minimumOSVersion: String?
    public var capabilitySummary: ModelCapabilitySummary
    public var files: [ModelPackageFile]

    public init(
        formatVersion: Int = ModelPackageManifest.currentFormatVersion,
        modelId: String,
        displayName: String,
        backendKind: ModelBackendKind,
        minimumOSVersion: String? = nil,
        capabilitySummary: ModelCapabilitySummary,
        files: [ModelPackageFile]
    ) {
        self.formatVersion = formatVersion
        self.modelId = modelId
        self.displayName = displayName
        self.backendKind = backendKind
        self.minimumOSVersion = minimumOSVersion
        self.capabilitySummary = capabilitySummary
        self.files = files
    }
}

public struct ModelCatalogEntry: Codable, Hashable, Identifiable, Sendable {
    public let catalogId: String
    public var sourceModelID: String
    public var displayName: String
    public var serverIdentifier: String
    public let backendKind: ModelBackendKind
    public var localPath: String?
    public var packageRootPath: String?
    public var manifestPath: String?
    public var importSource: ModelImportSource
    public var isServerExposed: Bool
    public var aliases: [String]
    public var capabilitySummary: ModelCapabilitySummary
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { catalogId }

    public init(
        catalogId: String,
        sourceModelID: String,
        displayName: String,
        serverIdentifier: String,
        backendKind: ModelBackendKind,
        localPath: String? = nil,
        packageRootPath: String? = nil,
        manifestPath: String? = nil,
        importSource: ModelImportSource,
        isServerExposed: Bool = true,
        aliases: [String] = [],
        capabilitySummary: ModelCapabilitySummary,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.catalogId = catalogId
        self.sourceModelID = sourceModelID
        self.displayName = displayName
        self.serverIdentifier = serverIdentifier
        self.backendKind = backendKind
        self.localPath = localPath
        self.packageRootPath = packageRootPath
        self.manifestPath = manifestPath
        self.importSource = importSource
        self.isServerExposed = isServerExposed
        self.aliases = aliases
        self.capabilitySummary = capabilitySummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isBuiltInAppleModel: Bool {
        catalogId == SystemModelCatalog.appleFoundationCatalogID
    }

    public var localFileURL: URL? {
        guard let localPath, !localPath.isEmpty else { return nil }
        return URL(fileURLWithPath: localPath)
    }

    public var packageRootURL: URL? {
        guard let packageRootPath, !packageRootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: packageRootPath)
    }

    public var manifestURL: URL? {
        guard let manifestPath, !manifestPath.isEmpty else { return nil }
        return URL(fileURLWithPath: manifestPath)
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: capabilitySummary.sizeBytes, countStyle: .file)
    }

    public var runtimeContextLength: Int {
        max(capabilitySummary.contextLength, 512)
    }

    public func matchesReference(_ candidate: String) -> Bool {
        allReferenceTokens().contains(candidate.trimmedForLookup.lowercased())
    }

    public func allReferenceTokens() -> [String] {
        let rawValues = [
            catalogId,
            sourceModelID,
            displayName,
            serverIdentifier,
            localPath
        ] + aliases

        var deduplicated: [String] = []
        var seen = Set<String>()

        for rawValue in rawValues {
            let normalized = rawValue.trimmedForLookup.lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            deduplicated.append(normalized)
        }

        return deduplicated
    }
}

public struct LegacyDownloadedModelSeed: Sendable {
    public let name: String
    public let modelId: String
    public let localPath: String
    public let size: Int64
    public let downloadDate: Date
    public let isDownloaded: Bool
    public let quantization: String
    public let parameters: String
    public let contextLength: Int

    public init(
        name: String,
        modelId: String,
        localPath: String,
        size: Int64,
        downloadDate: Date,
        isDownloaded: Bool,
        quantization: String,
        parameters: String,
        contextLength: Int
    ) {
        self.name = name
        self.modelId = modelId
        self.localPath = localPath
        self.size = size
        self.downloadDate = downloadDate
        self.isDownloaded = isDownloaded
        self.quantization = quantization
        self.parameters = parameters
        self.contextLength = contextLength
    }
}

public struct RuntimePreferences: Hashable, Sendable {
    public var contextLength: Int
    public var gpuLayers: Int
    public var threads: Int
    public var batchSize: Int
    public var flashAttentionEnabled: Bool
    public var mmapEnabled: Bool
    public var mlockEnabled: Bool
    public var keepModelInMemory: Bool
    public var autoOffloadMinutes: Int

    public init(
        contextLength: Int = 4096,
        gpuLayers: Int = 0,
        threads: Int = 1,
        batchSize: Int = 512,
        flashAttentionEnabled: Bool = false,
        mmapEnabled: Bool = true,
        mlockEnabled: Bool = false,
        keepModelInMemory: Bool = false,
        autoOffloadMinutes: Int = 5
    ) {
        self.contextLength = max(contextLength, 512)
        self.gpuLayers = max(gpuLayers, 0)
        self.threads = max(threads, 1)
        self.batchSize = max(batchSize, 32)
        self.flashAttentionEnabled = flashAttentionEnabled
        self.mmapEnabled = mmapEnabled
        self.mlockEnabled = mlockEnabled
        self.keepModelInMemory = keepModelInMemory
        self.autoOffloadMinutes = max(autoOffloadMinutes, 1)
    }
}

public struct ConversationTurn: Codable, Hashable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct SamplingParameters: Codable, Hashable, Sendable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var repeatPenalty: Double
    public var repeatLastN: Int
    public var maxTokens: Int
    public var stopSequences: [String]

    public init(
        temperature: Double = 0.7,
        topP: Double = 0.9,
        topK: Int = 40,
        repeatPenalty: Double = 1.1,
        repeatLastN: Int = 64,
        maxTokens: Int = 1024,
        stopSequences: [String] = []
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }

    public static var `default`: SamplingParameters {
        SamplingParameters()
    }
}

public struct InferenceRequest: Sendable {
    public let catalogId: String
    public let prompt: String
    public let systemPrompt: String?
    public let parameters: SamplingParameters
    public let runtimePreferences: RuntimePreferences

    public init(
        catalogId: String,
        prompt: String,
        systemPrompt: String? = nil,
        parameters: SamplingParameters = .default,
        runtimePreferences: RuntimePreferences
    ) {
        self.catalogId = catalogId
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.parameters = parameters
        self.runtimePreferences = runtimePreferences
    }
}

public struct InferenceChunk: Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct InferenceResult: Sendable {
    public let text: String
    public let tokensGenerated: Int
    public let promptTokens: Int
    public let generationTime: Double
    public let tokensPerSecond: Double
    public let wasCancelled: Bool

    public init(
        text: String,
        tokensGenerated: Int,
        promptTokens: Int,
        generationTime: Double,
        tokensPerSecond: Double,
        wasCancelled: Bool
    ) {
        self.text = text
        self.tokensGenerated = tokensGenerated
        self.promptTokens = promptTokens
        self.generationTime = generationTime
        self.tokensPerSecond = tokensPerSecond
        self.wasCancelled = wasCancelled
    }

    public var totalTokens: Int {
        tokensGenerated + promptTokens
    }
}

public enum InferenceError: Error, LocalizedError, Sendable {
    case modelNotFound(String)
    case invalidPath
    case noModelSelected
    case noModelLoaded
    case failedToLoadModel
    case failedToCreateContext
    case failedToInitializeBackend
    case tokenizationError
    case decodeError
    case generationCancelled
    case appleModelUnavailable(String)
    case unsupportedBackend(String)
    case backendUnavailable(String)
    case importFailed(String)
    case registryFailure(String)
    case compatibilityFailure(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let detail):
            return detail
        case .invalidPath:
            return "Invalid model path. Please re-import or re-download the model."
        case .noModelSelected:
            return "No model is currently selected."
        case .noModelLoaded:
            return "No model is currently loaded."
        case .failedToLoadModel:
            return "Failed to load the GGUF model with llama.cpp."
        case .failedToCreateContext:
            return "Failed to create the llama.cpp inference context."
        case .failedToInitializeBackend:
            return "Failed to initialize the selected inference backend."
        case .tokenizationError:
            return "Failed to tokenize the prompt for inference."
        case .decodeError:
            return "Model decoding failed."
        case .generationCancelled:
            return "Generation was cancelled."
        case .appleModelUnavailable(let message),
             .unsupportedBackend(let message),
             .backendUnavailable(let message),
             .importFailed(let message),
             .registryFailure(let message),
             .compatibilityFailure(let message):
            return message
        }
    }
}

public struct DeviceProfile: Hashable, Sendable {
    public let machineIdentifier: String
    public let chipFamily: String
    public let systemVersion: String
    public let physicalMemoryBytes: Int64
    public let recommendedGGUFBudgetBytes: Int64
    public let supportedGGUFBudgetBytes: Int64

    public init(
        machineIdentifier: String,
        chipFamily: String,
        systemVersion: String,
        physicalMemoryBytes: Int64,
        recommendedGGUFBudgetBytes: Int64,
        supportedGGUFBudgetBytes: Int64
    ) {
        self.machineIdentifier = machineIdentifier
        self.chipFamily = chipFamily
        self.systemVersion = systemVersion
        self.physicalMemoryBytes = physicalMemoryBytes
        self.recommendedGGUFBudgetBytes = recommendedGGUFBudgetBytes
        self.supportedGGUFBudgetBytes = supportedGGUFBudgetBytes
    }

    public var deviceLabel: String {
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "This iPad"
        case .phone:
            return "This iPhone"
        default:
            return "This Device"
        }
        #else
        return "This Device"
        #endif
    }

    public var formattedPhysicalMemory: String {
        ByteCountFormatter.string(fromByteCount: physicalMemoryBytes, countStyle: .memory)
    }

    public var formattedRecommendedBudget: String {
        ByteCountFormatter.string(fromByteCount: recommendedGGUFBudgetBytes, countStyle: .file)
    }

    public var formattedSupportedBudget: String {
        ByteCountFormatter.string(fromByteCount: supportedGGUFBudgetBytes, countStyle: .file)
    }
}

public struct CompatibilityReport: Hashable, Sendable {
    public let backendKind: ModelBackendKind
    public let level: ModelCompatibilityLevel
    public let title: String
    public let message: String

    public init(
        backendKind: ModelBackendKind,
        level: ModelCompatibilityLevel,
        title: String,
        message: String
    ) {
        self.backendKind = backendKind
        self.level = level
        self.title = title
        self.message = message
    }

    public var isUsable: Bool {
        level.isUsable
    }
}

public enum SystemModelCatalog {
    public static let appleFoundationCatalogID = "apple/foundation-model"
    public static let appleFoundationModelName = "Apple On-Device"

    public static func appleFoundationEntry(contextLength: Int = 4096) -> ModelCatalogEntry {
        let capability = ModelCapabilitySummary(
            sizeBytes: 0,
            quantization: "Apple AI",
            parameterCountLabel: "Built In",
            contextLength: max(contextLength, 2048),
            supportsStreaming: false,
            notes: "Uses Apple's built-in on-device Foundation Models runtime."
        )

        return ModelCatalogEntry(
            catalogId: appleFoundationCatalogID,
            sourceModelID: appleFoundationCatalogID,
            displayName: appleFoundationModelName,
            serverIdentifier: appleFoundationCatalogID,
            backendKind: .appleFoundation,
            importSource: .builtIn,
            isServerExposed: true,
            aliases: [
                appleFoundationModelName,
                "\(appleFoundationCatalogID)#\(appleFoundationModelName)"
            ],
            capabilitySummary: capability,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}

public protocol InferenceBackend: AnyObject {
    var kind: ModelBackendKind { get }
    var activeCatalogId: String? { get }

    func load(entry: ModelCatalogEntry, runtime: RuntimePreferences) async throws
    func unload() async
    func generate(
        entry: ModelCatalogEntry,
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult
    func stopGeneration() async
}

public extension String {
    var trimmedForLookup: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nonEmpty: String? {
        let trimmed = trimmedForLookup
        return trimmed.isEmpty ? nil : trimmed
    }
}
