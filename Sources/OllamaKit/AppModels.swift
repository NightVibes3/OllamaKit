import Foundation
import SwiftData
import SwiftUI
import UIKit

@Model
final class DownloadedModel {
    var id: UUID
    var name: String
    var modelId: String
    var localPath: String
    var size: Int64
    var downloadDate: Date
    var isDownloaded: Bool
    var isFavorite: Bool
    var quantization: String
    var parameters: String
    var contextLength: Int

    init(
        name: String,
        modelId: String,
        localPath: String = "",
        size: Int64 = 0,
        downloadDate: Date = .now,
        isDownloaded: Bool = false,
        isFavorite: Bool = false,
        quantization: String = "GGUF",
        parameters: String = "Unknown",
        contextLength: Int = 4096
    ) {
        self.id = UUID()
        self.name = name
        self.modelId = modelId
        self.localPath = localPath
        self.size = size
        self.downloadDate = downloadDate
        self.isDownloaded = isDownloaded
        self.isFavorite = isFavorite
        self.quantization = quantization
        self.parameters = parameters
        self.contextLength = contextLength
    }

    var displayName: String {
        if !name.isEmpty {
            return name
        }

        let modelName = modelId.split(separator: "/").last.map(String.init)
        return modelName?.replacingOccurrences(of: ".gguf", with: "") ?? modelId
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var fileExists: Bool {
        !localPath.isEmpty && FileManager.default.fileExists(atPath: localPath)
    }

    var runtimeContextLength: Int {
        max(AppSettings.shared.defaultContextLength, 512)
    }

    var persistentReference: String {
        apiIdentifier
    }

    var apiIdentifier: String {
        guard let name = name.nonEmpty else {
            return modelId
        }

        return "\(modelId)#\(name)"
    }

    func matchesStoredReference(_ candidate: String) -> Bool {
        matchPriority(forStoredReference: candidate) != nil
    }

    func matchPriority(forStoredReference candidate: String) -> Int? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else { return nil }

        if localPath.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 0
        }

        if apiIdentifier.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 1
        }

        if modelId.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 2
        }

        if name.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 3
        }

        if displayName.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 4
        }

        return nil
    }

    static func resolveStoredReference(_ candidate: String, in models: [DownloadedModel]) -> DownloadedModel? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else { return nil }

        return models
            .compactMap { model in
                model.matchPriority(forStoredReference: normalizedCandidate).map { ($0, model) }
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
}

enum ChatRole: String, Codable, CaseIterable {
    case system
    case user
    case assistant
}

@Model
final class ChatSession {
    var id: UUID
    var title: String
    var modelId: String
    var systemPrompt: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage]?

    init(
        title: String? = nil,
        modelId: String,
        systemPrompt: String = "You are a helpful assistant.",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [ChatMessage]? = []
    ) {
        self.id = UUID()
        self.title = title ?? "New Chat"
        self.modelId = modelId
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    var orderedMessages: [ChatMessage] {
        (messages ?? []).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

@Model
final class ChatMessage {
    var id: UUID
    var roleValue: String
    var content: String
    var createdAt: Date
    var tokenCount: Int
    var generationTime: Double
    var isGenerating: Bool
    var session: ChatSession?

    init(
        role: ChatRole,
        content: String,
        createdAt: Date = .now,
        tokenCount: Int = 0,
        generationTime: Double = 0,
        isGenerating: Bool = false
    ) {
        self.id = UUID()
        self.roleValue = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.tokenCount = tokenCount
        self.generationTime = generationTime
        self.isGenerating = isGenerating
    }

    var role: ChatRole {
        get { ChatRole(rawValue: roleValue) ?? .assistant }
        set { roleValue = newValue.rawValue }
    }
}

struct HuggingFaceModel: Decodable, Identifiable, Hashable {
    let id: String
    let description: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]?

    var modelId: String { id }

    var displayName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    var organization: String {
        let components = id.split(separator: "/").map(String.init)
        if components.count > 1 {
            return components.dropLast().joined(separator: "/")
        }
        return "Hugging Face"
    }
}

struct GGUFInfo: Identifiable, Hashable {
    let url: URL
    let filename: String
    let size: Int64?
    let quantization: String?

    var id: String { url.absoluteString }
    var displayName: String { filename }
}

struct ModelParameters {
    var temperature: Double
    var topP: Double
    var topK: Int
    var repeatPenalty: Double
    var maxTokens: Int

    static var `default`: ModelParameters {
        let settings = AppSettings.shared
        return ModelParameters(
            temperature: settings.defaultTemperature,
            topP: settings.defaultTopP,
            topK: settings.defaultTopK,
            repeatPenalty: settings.defaultRepeatPenalty,
            maxTokens: settings.maxTokens
        )
    }
}

struct PromptTurn: Sendable {
    let role: String
    let content: String
}

enum PromptComposer {
    static func compose(
        systemPrompt: String? = nil,
        messages: [PromptTurn],
        appendAssistantCue: Bool = false
    ) -> String {
        let systemBlock = systemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            .map { "System:\n\($0)" }

        let conversation = messages
            .map { message in
                let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                return "\(role):\n\(content)"
            }
            .compactMap { $0 }
            .joined(separator: "\n\n")

        let assistantCue = appendAssistantCue ? "Assistant:\n" : nil

        return [systemBlock, conversation.nonEmpty, assistantCue]
            .compactMap { $0 }
            .joined(separator: "\n\n")
            .nonEmpty ?? ""
    }
}

enum HapticManager {
    @MainActor
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard AppSettings.shared.hapticFeedback else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    @MainActor
    static func selectionChanged() {
        guard AppSettings.shared.hapticFeedback else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    @MainActor
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard AppSettings.shared.hapticFeedback else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ModelPathHelper {
    static var modelsDirectoryURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return documents.appendingPathComponent("Models", isDirectory: true)
    }

    static func ensureModelsDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: modelsDirectoryURL,
            withIntermediateDirectories: true
        )
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var defaultTemperature: Double { didSet { save(defaultTemperature, for: Keys.defaultTemperature) } }
    @Published var defaultTopP: Double { didSet { save(defaultTopP, for: Keys.defaultTopP) } }
    @Published var defaultTopK: Int { didSet { save(defaultTopK, for: Keys.defaultTopK) } }
    @Published var defaultRepeatPenalty: Double { didSet { save(defaultRepeatPenalty, for: Keys.defaultRepeatPenalty) } }
    @Published var defaultRepeatLastN: Int { didSet { save(defaultRepeatLastN, for: Keys.defaultRepeatLastN) } }
    @Published var defaultContextLength: Int { didSet { save(defaultContextLength, for: Keys.defaultContextLength) } }
    @Published var maxTokens: Int { didSet { save(maxTokens, for: Keys.maxTokens) } }

    @Published var threads: Int { didSet { save(threads, for: Keys.threads) } }
    @Published var batchSize: Int { didSet { save(batchSize, for: Keys.batchSize) } }
    @Published var gpuLayers: Int { didSet { save(gpuLayers, for: Keys.gpuLayers) } }
    @Published var flashAttentionEnabled: Bool { didSet { save(flashAttentionEnabled, for: Keys.flashAttentionEnabled) } }
    @Published var mmapEnabled: Bool { didSet { save(mmapEnabled, for: Keys.mmapEnabled) } }
    @Published var mlockEnabled: Bool { didSet { save(mlockEnabled, for: Keys.mlockEnabled) } }
    @Published var keepModelInMemory: Bool { didSet { save(keepModelInMemory, for: Keys.keepModelInMemory) } }
    @Published var autoOffloadMinutes: Int { didSet { save(autoOffloadMinutes, for: Keys.autoOffloadMinutes) } }

    @Published var huggingFaceToken: String { didSet { save(huggingFaceToken, for: Keys.huggingFaceToken) } }

    @Published var darkMode: Bool { didSet { save(darkMode, for: Keys.darkMode) } }
    @Published var hapticFeedback: Bool { didSet { save(hapticFeedback, for: Keys.hapticFeedback) } }
    @Published var showTokenCount: Bool { didSet { save(showTokenCount, for: Keys.showTokenCount) } }
    @Published var showGenerationSpeed: Bool { didSet { save(showGenerationSpeed, for: Keys.showGenerationSpeed) } }
    @Published var markdownRendering: Bool { didSet { save(markdownRendering, for: Keys.markdownRendering) } }
    @Published var streamingEnabled: Bool { didSet { save(streamingEnabled, for: Keys.streamingEnabled) } }

    @Published var serverEnabled: Bool { didSet { save(serverEnabled, for: Keys.serverEnabled) } }
    @Published var serverPort: Int { didSet { save(serverPort, for: Keys.serverPort) } }
    @Published var allowExternalConnections: Bool { didSet { save(allowExternalConnections, for: Keys.allowExternalConnections) } }
    @Published var requireApiKey: Bool { didSet { save(requireApiKey, for: Keys.requireApiKey) } }
    @Published var apiKey: String { didSet { save(apiKey, for: Keys.apiKey) } }
    @Published var defaultModelId: String { didSet { save(defaultModelId, for: Keys.defaultModelId) } }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaultTemperature = defaults.object(forKey: Keys.defaultTemperature) as? Double ?? 0.7
        defaultTopP = defaults.object(forKey: Keys.defaultTopP) as? Double ?? 0.9
        defaultTopK = defaults.object(forKey: Keys.defaultTopK) as? Int ?? 40
        defaultRepeatPenalty = defaults.object(forKey: Keys.defaultRepeatPenalty) as? Double ?? 1.1
        defaultRepeatLastN = defaults.object(forKey: Keys.defaultRepeatLastN) as? Int ?? 64
        defaultContextLength = defaults.object(forKey: Keys.defaultContextLength) as? Int ?? 4096
        maxTokens = defaults.object(forKey: Keys.maxTokens) as? Int ?? 1024

        threads = defaults.object(forKey: Keys.threads) as? Int ?? max(ProcessInfo.processInfo.processorCount - 1, 1)
        batchSize = defaults.object(forKey: Keys.batchSize) as? Int ?? 512
        gpuLayers = defaults.object(forKey: Keys.gpuLayers) as? Int ?? 0
        flashAttentionEnabled = defaults.object(forKey: Keys.flashAttentionEnabled) as? Bool ?? false
        mmapEnabled = defaults.object(forKey: Keys.mmapEnabled) as? Bool ?? true
        mlockEnabled = defaults.object(forKey: Keys.mlockEnabled) as? Bool ?? false
        keepModelInMemory = defaults.object(forKey: Keys.keepModelInMemory) as? Bool ?? false
        autoOffloadMinutes = defaults.object(forKey: Keys.autoOffloadMinutes) as? Int ?? 5

        huggingFaceToken = defaults.string(forKey: Keys.huggingFaceToken) ?? ""

        darkMode = defaults.object(forKey: Keys.darkMode) as? Bool ?? true
        hapticFeedback = defaults.object(forKey: Keys.hapticFeedback) as? Bool ?? true
        showTokenCount = defaults.object(forKey: Keys.showTokenCount) as? Bool ?? true
        showGenerationSpeed = defaults.object(forKey: Keys.showGenerationSpeed) as? Bool ?? true
        markdownRendering = defaults.object(forKey: Keys.markdownRendering) as? Bool ?? true
        streamingEnabled = defaults.object(forKey: Keys.streamingEnabled) as? Bool ?? true

        serverEnabled = defaults.object(forKey: Keys.serverEnabled) as? Bool ?? false
        serverPort = defaults.object(forKey: Keys.serverPort) as? Int ?? 11434
        allowExternalConnections = defaults.object(forKey: Keys.allowExternalConnections) as? Bool ?? false
        requireApiKey = defaults.object(forKey: Keys.requireApiKey) as? Bool ?? false
        apiKey = defaults.string(forKey: Keys.apiKey) ?? String(UUID().uuidString.prefix(16)).uppercased()
        defaultModelId = defaults.string(forKey: Keys.defaultModelId) ?? ""
    }

    var localServerURL: String {
        "http://127.0.0.1:\(serverPort)"
    }

    var serverURL: String {
        localServerURL
    }

    func resetToDefaults() {
        defaultTemperature = 0.7
        defaultTopP = 0.9
        defaultTopK = 40
        defaultRepeatPenalty = 1.1
        defaultRepeatLastN = 64
        defaultContextLength = 4096
        maxTokens = 1024

        threads = max(ProcessInfo.processInfo.processorCount - 1, 1)
        batchSize = 512
        gpuLayers = 0
        flashAttentionEnabled = false
        mmapEnabled = true
        mlockEnabled = false
        keepModelInMemory = false
        autoOffloadMinutes = 5

        huggingFaceToken = ""

        darkMode = true
        hapticFeedback = true
        showTokenCount = true
        showGenerationSpeed = true
        markdownRendering = true
        streamingEnabled = true

        serverEnabled = false
        serverPort = 11434
        allowExternalConnections = false
        requireApiKey = false
        apiKey = String(UUID().uuidString.prefix(16)).uppercased()
        defaultModelId = ""
    }

    private func save(_ value: Any?, for key: String) {
        defaults.set(value, forKey: key)
    }

    private enum Keys {
        static let defaultTemperature = "defaultTemperature"
        static let defaultTopP = "defaultTopP"
        static let defaultTopK = "defaultTopK"
        static let defaultRepeatPenalty = "defaultRepeatPenalty"
        static let defaultRepeatLastN = "defaultRepeatLastN"
        static let defaultContextLength = "defaultContextLength"
        static let maxTokens = "maxTokens"

        static let threads = "threads"
        static let batchSize = "batchSize"
        static let gpuLayers = "gpuLayers"
        static let flashAttentionEnabled = "flashAttentionEnabled"
        static let mmapEnabled = "mmapEnabled"
        static let mlockEnabled = "mlockEnabled"
        static let keepModelInMemory = "keepModelInMemory"
        static let autoOffloadMinutes = "autoOffloadMinutes"

        static let huggingFaceToken = "huggingFaceToken"

        static let darkMode = "darkMode"
        static let hapticFeedback = "hapticFeedback"
        static let showTokenCount = "showTokenCount"
        static let showGenerationSpeed = "showGenerationSpeed"
        static let markdownRendering = "markdownRendering"
        static let streamingEnabled = "streamingEnabled"

        static let serverEnabled = "serverEnabled"
        static let serverPort = "serverPort"
        static let allowExternalConnections = "allowExternalConnections"
        static let requireApiKey = "requireApiKey"
        static let apiKey = "apiKey"
        static let defaultModelId = "defaultModelId"
    }
}
