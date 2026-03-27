import Foundation
import Alamofire
import SwiftyJSON

actor HuggingFaceService {
    static let shared = HuggingFaceService()
    
    private let baseURL = "https://huggingface.co/api"
    private let downloadBaseURL = "https://huggingface.co"
    
    private var activeDownloads: [String: DownloadTask] = [:]
    
    private init() {}
    
    // MARK: - Search Models
    
    func searchModels(query: String, limit: Int = 20) async throws -> [HuggingFaceModel] {
        let url = "\(baseURL)/models"
        let parameters: [String: Any] = [
            "search": query,
            "limit": limit,
            "sort": "downloads",
            "direction": -1,
            "filter": "gguf"
        ]
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(AppSettings.shared.huggingFaceToken)"
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, parameters: parameters, headers: headers)
                .validate()
                .responseData { response in
                    switch response.result {
                    case .success(let data):
                        do {
                            let models = try JSONDecoder().decode([HuggingFaceModel].self, from: data)
                            continuation.resume(returning: models)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    func getTrendingModels(limit: Int = 20) async throws -> [HuggingFaceModel] {
        let url = "\(baseURL)/models"
        let parameters: [String: Any] = [
            "limit": limit,
            "sort": "downloads",
            "direction": -1,
            "filter": "gguf"
        ]
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(AppSettings.shared.huggingFaceToken)"
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, parameters: parameters, headers: headers)
                .validate()
                .responseData { response in
                    switch response.result {
                    case .success(let data):
                        do {
                            let models = try JSONDecoder().decode([HuggingFaceModel].self, from: data)
                            continuation.resume(returning: models)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    // MARK: - Get Model Files
    
    func getModelFiles(modelId: String) async throws -> [GGUFInfo] {
        let url = "\(baseURL)/models/\(modelId)/tree/main"
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(AppSettings.shared.huggingFaceToken)"
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, headers: headers)
                .validate()
                .responseData { response in
                    switch response.result {
                    case .success(let data):
                        do {
                            let json = try JSON(data: data)
                            var files: [GGUFInfo] = []
                            
                            for (_, fileJson) in json {
                                if let path = fileJson["path"].string,
                                   path.hasSuffix(".gguf") {
                                    let size = fileJson["size"].int64
                                    let url = URL(string: "\(self.downloadBaseURL)/\(modelId)/resolve/main/\(path)")!
                                    
                                    // Extract quantization from filename
                                    let filename = (path as NSString).lastPathComponent
                                    let quantization = self.extractQuantization(from: filename)
                                    
                                    files.append(GGUFInfo(
                                        url: url,
                                        filename: filename,
                                        size: size,
                                        quantization: quantization
                                    ))
                                }
                            }
                            
                            continuation.resume(returning: files)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    private func extractQuantization(from filename: String) -> String? {
        let patterns = [
            "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L",
            "Q4_0", "Q4_K_S", "Q4_K_M",
            "Q5_0", "Q5_K_S", "Q5_K_M",
            "Q6_K", "Q8_0",
            "FP16", "FP32"
        ]
        
        for pattern in patterns {
            if filename.contains(pattern) {
                return pattern
            }
        }
        return nil
    }
    
    // MARK: - Download
    
    func downloadModel(
        from url: URL,
        filename: String,
        modelId: String,
        progressHandler: @escaping (DownloadProgress) -> Void
    ) async throws -> DownloadedModel {
        // Use the ModelPathHelper to ensure consistent path handling
        let modelDir = ModelPathHelper.modelsDirectoryURL
        
        // Ensure the Models directory exists
        do {
            try ModelPathHelper.ensureModelsDirectoryExists()
        } catch {
            throw NSError(domain: "HuggingFaceService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to create Models directory"])
        }
        
        let destinationURL = modelDir.appendingPathComponent(filename)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: destinationURL)
        
        let downloadId = UUID().uuidString
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = AF.download(url, to: { _, _ in
                return (destinationURL, [.removePreviousFile, .createIntermediateDirectories])
            })
            .downloadProgress { progress in
                let downloadProgress = DownloadProgress(
                    totalBytes: progress.totalUnitCount,
                    downloadedBytes: progress.completedUnitCount,
                    progress: progress.fractionCompleted,
                    speed: 0 // Calculate if needed
                )
                Task { @MainActor in
                    progressHandler(downloadProgress)
                }
            }
            .response { response in
                self.activeDownloads.removeValue(forKey: downloadId)
                
                switch response.result {
                case .success:
                    do {
                        let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
                        let fileSize = attributes[.size] as? Int64 ?? 0
                        
                        let model = DownloadedModel(
                            name: filename.replacingOccurrences(of: ".gguf", with: ""),
                            modelId: modelId,
                            localPath: destinationURL.path,
                            size: fileSize,
                            isDownloaded: true
                        )
                        continuation.resume(returning: model)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            activeDownloads[downloadId] = DownloadTask(request: request)
        }
    }
    
    func cancelDownload(id: String) {
        activeDownloads[id]?.request.cancel()
        activeDownloads.removeValue(forKey: id)
    }
    
    func getModelInfo(modelId: String) async throws -> ModelInfo {
        let url = "\(baseURL)/models/\(modelId)"
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(AppSettings.shared.huggingFaceToken)"
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, headers: headers)
                .validate()
                .responseData { response in
                    switch response.result {
                    case .success(let data):
                        do {
                            let json = try JSON(data: data)
                            let info = ModelInfo(
                                id: json["id"].stringValue,
                                description: json["description"].string,
                                tags: json["tags"].arrayObject as? [String] ?? [],
                                downloads: json["downloads"].intValue,
                                likes: json["likes"].intValue,
                                author: json["author"].string
                            )
                            continuation.resume(returning: info)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
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

struct DownloadTask {
    let request: DownloadRequest
}

struct ModelInfo {
    let id: String
    let description: String?
    let tags: [String]
    let downloads: Int
    let likes: Int
    let author: String?
}
