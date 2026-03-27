import SwiftUI
import SwiftData

@main
struct OllamaKitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    let container: ModelContainer
    
    init() {
        do {
            let schema = Schema([
                DownloadedModel.self,
                ChatSession.self,
                ChatMessage.self
            ])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Start background server if enabled
        Task {
            await ServerManager.shared.startServerIfEnabled()
        }
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Keep server running in background
        BackgroundTaskManager.shared.scheduleBackgroundTask()
    }
}
