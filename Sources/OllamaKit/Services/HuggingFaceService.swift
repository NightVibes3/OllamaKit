import Foundation

final class HuggingFaceService {
    static let shared = HuggingFaceService()

    private struct ActiveDownload {
        let token: UUID
        let task: URLSessionDownloadTask
        let observation: NSKeyValueObservation
    }

    private let baseURL = URL(string: "https://huggingface.co/api")!
    private let downloadBaseURL = URL(string: "https://huggingface.co")!
    private let session: URLSession
    private let activeDownloadsLock = NSLock()
    private var activeDownloads: [String: ActiveDownload] = [:]

    private init(session: URLSession = .shared) {
        self.session = session
    }

    func searchModels(query: String, limit: Int = 20) async throws -> [HuggingFaceModel] {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "filter", value: "gguf")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response: response)
        return try JSONDecoder().decode([HuggingFaceModel].self, from: data)
    }

    func getTrendingModels(limit: Int = 20) async throws -> [HuggingFaceModel] {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "filter", value: "gguf")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response: response)
        return try JSONDecoder().decode([HuggingFaceModel].self, from: data)
    }

    func getModelFiles(modelId: String) async throws -> [GGUFInfo] {
        let url = repoAPIURL(modelId: modelId, suffix: ["tree", "main"])
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response: response)

        guard let rawFiles = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return rawFiles.compactMap { file in
            guard let path = file["path"] as? String, path.lowercased().hasSuffix(".gguf") else {
                return nil
            }

            let filename = URL(fileURLWithPath: path).lastPathComponent
            return GGUFInfo(
                url: repoDownloadURL(modelId: modelId, suffix: ["resolve", "main"] + path.split(separator: "/").map(String.init)),
                filename: filename,
                size: file["size"] as? Int64 ?? (file["size"] as? NSNumber)?.int64Value,
                quantization: extractQuantization(from: filename)
            )
        }
        .sorted { lhs, rhs in
            (lhs.size ?? 0) < (rhs.size ?? 0)
        }
    }

    func downloadModel(
        from url: URL,
        filename: String,
        modelId: String,
        progressHandler: @escaping (DownloadProgress) -> Void
    ) async throws -> DownloadedModel {
        try ModelPathHelper.ensureModelsDirectoryExists()

        var destinationDirectory = ModelPathHelper.modelsDirectoryURL
        for component in modelId.split(separator: "/").map(String.init) {
            destinationDirectory.appendPathComponent(component, isDirectory: true)
        }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let destinationURL = destinationDirectory.appendingPathComponent(filename)
        let stagedURL = destinationDirectory.appendingPathComponent("\(filename).download-\(UUID().uuidString)")

        progressHandler(DownloadProgress(totalBytes: 0, downloadedBytes: 0, progress: 0, speed: 0))

        do {
            let (temporaryURL, response) = try await download(
                request: authorizedRequest(url: url),
                id: url.absoluteString,
                progressHandler: progressHandler
            )
            try validate(response: response)
            try Task.checkCancellation()

            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.moveItem(at: temporaryURL, to: stagedURL)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)

            let fileSize = (try FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            progressHandler(DownloadProgress(totalBytes: fileSize, downloadedBytes: fileSize, progress: 1, speed: 0))

            return DownloadedModel(
                name: filename.replacingOccurrences(of: ".gguf", with: ""),
                modelId: modelId,
                localPath: destinationURL.path,
                size: fileSize,
                downloadDate: .now,
                isDownloaded: true,
                quantization: extractQuantization(from: filename) ?? "GGUF",
                parameters: inferParameterSize(from: filename),
                contextLength: AppSettings.shared.defaultContextLength
            )
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
    }

    func cancelDownload(id: String) {
        activeDownloadsLock.lock()
        activeDownloads[id]?.task.cancel()
        activeDownloadsLock.unlock()
    }

    func getModelInfo(modelId: String) async throws -> ModelInfo {
        let url = repoAPIURL(modelId: modelId)
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response: response)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        return ModelInfo(
            id: json["id"] as? String ?? modelId,
            description: json["description"] as? String,
            tags: json["tags"] as? [String] ?? [],
            downloads: json["downloads"] as? Int ?? 0,
            likes: json["likes"] as? Int ?? 0,
            author: json["author"] as? String
        )
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let token = AppSettings.shared.huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "HuggingFaceService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Hugging Face request failed with status \(httpResponse.statusCode)."]
            )
        }
    }

    private func download(
        request: URLRequest,
        id: String,
        progressHandler: @escaping (DownloadProgress) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let downloadToken = UUID()
            let startedAt = Date()
            let task = session.downloadTask(with: request) { [weak self] temporaryURL, response, error in
                var completedDownload: ActiveDownload?
                if let self {
                    self.activeDownloadsLock.lock()
                    if let activeDownload = self.activeDownloads[id], activeDownload.token == downloadToken {
                        completedDownload = self.activeDownloads.removeValue(forKey: id)
                    }
                    self.activeDownloadsLock.unlock()
                }
                completedDownload?.observation.invalidate()

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let temporaryURL, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                continuation.resume(returning: (temporaryURL, response))
            }

            let observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                let totalBytes = max(progress.totalUnitCount, Int64(0))
                let downloadedBytes = max(progress.completedUnitCount, Int64(0))
                let normalizedProgress: Double

                if totalBytes > 0 {
                    normalizedProgress = min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
                } else {
                    normalizedProgress = min(max(progress.fractionCompleted, 0), 1)
                }

                let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                progressHandler(
                    DownloadProgress(
                        totalBytes: totalBytes,
                        downloadedBytes: downloadedBytes,
                        progress: normalizedProgress,
                        speed: Double(downloadedBytes) / elapsed
                    )
                )
            }

            activeDownloadsLock.lock()
            if let existingDownload = activeDownloads[id] {
                existingDownload.task.cancel()
                existingDownload.observation.invalidate()
            }
            activeDownloads[id] = ActiveDownload(token: downloadToken, task: task, observation: observation)
            activeDownloadsLock.unlock()

            task.resume()
        }
    }

    private func extractQuantization(from filename: String) -> String? {
        let patterns = [
            "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L",
            "Q4_0", "Q4_K_S", "Q4_K_M",
            "Q5_0", "Q5_K_S", "Q5_K_M",
            "Q6_K", "Q8_0", "F16", "FP16", "FP32"
        ]

        return patterns.first { filename.localizedCaseInsensitiveContains($0) }
    }

    private func inferParameterSize(from filename: String) -> String {
        let matches = filename.range(of: "\\d+(\\.\\d+)?[Bb]", options: .regularExpression)
        return matches.map { String(filename[$0]) } ?? "Unknown"
    }

    private func repoAPIURL(modelId: String, suffix: [String] = []) -> URL {
        var url = baseURL.appendingPathComponent("models")
        for component in modelId.split(separator: "/").map(String.init) + suffix {
            url.appendPathComponent(component)
        }
        return url
    }

    private func repoDownloadURL(modelId: String, suffix: [String]) -> URL {
        var url = downloadBaseURL
        for component in modelId.split(separator: "/").map(String.init) + suffix {
            url.appendPathComponent(component)
        }
        return url
    }
}

struct DownloadProgress {
    let totalBytes: Int64
    let downloadedBytes: Int64
    let progress: Double
    let speed: Double

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var formattedDownloaded: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var formattedSpeed: String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s"
    }

    var percentage: Int {
        Int(progress * 100)
    }
}

struct ModelInfo {
    let id: String
    let description: String?
    let tags: [String]
    let downloads: Int
    let likes: Int
    let author: String?
}
