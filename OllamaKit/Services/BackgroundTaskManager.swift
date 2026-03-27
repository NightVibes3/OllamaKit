import Foundation
import BackgroundTasks

class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    
    private let backgroundTaskIdentifier = "com.ollamakit.serverkeepalive"
    
    private init() {
        registerBackgroundTask()
    }
    
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { [weak self] task in
            self?.handleBackgroundTask(task as! BGProcessingTask)
        }
    }
    
    func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule background task: \(error)")
        }
    }
    
    private func handleBackgroundTask(_ task: BGProcessingTask) {
        scheduleBackgroundTask()
        
        Task {
            await ServerManager.shared.startServerIfEnabled()
            task.setTaskCompleted(success: true)
        }
        
        task.expirationHandler = {
            // Clean up if needed
        }
    }
}
