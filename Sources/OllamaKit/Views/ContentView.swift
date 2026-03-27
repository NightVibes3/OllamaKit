import SwiftUI
import SwiftData

struct ContentView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Chat Tab
            NavigationStack {
                ChatSessionsView()
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.fill")
            }
            .tag(0)
            
            // Models Tab
            NavigationStack {
                ModelsView()
            }
            .tabItem {
                Label("Models", systemImage: "cube.fill")
            }
            .tag(1)
            
            // Server Tab
            NavigationStack {
                ServerView()
            }
            .tabItem {
                Label("Server", systemImage: "network")
            }
            .tag(2)
            
            // Settings Tab
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(3)
        }
        .tint(.accentColor)
        .preferredColorScheme(settings.darkMode ? .dark : .light)
    }
}

// MARK: - Liquid Glass Modifier

struct LiquidGlassModifier: ViewModifier {
    var intensity: Double = 0.15
    var radius: CGFloat = 20
    
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, *) {
                content
                    .background(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(
                                MeshGradient(
                                    width: 3,
                                    height: 3,
                                    points: [
                                        .init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 1, y: 0),
                                        .init(x: 0, y: 0.5), .init(x: 0.5, y: 0.5), .init(x: 1, y: 0.5),
                                        .init(x: 0, y: 1), .init(x: 0.5, y: 1), .init(x: 1, y: 1)
                                    ],
                                    colors: [
                                        .accentColor.opacity(0.1),
                                        .accentColor.opacity(0.05),
                                        .accentColor.opacity(0.1),
                                        .accentColor.opacity(0.05),
                                        .accentColor.opacity(0.02),
                                        .accentColor.opacity(0.05),
                                        .accentColor.opacity(0.1),
                                        .accentColor.opacity(0.05),
                                        .accentColor.opacity(0.1)
                                    ]
                                )
                            )
                            .opacity(intensity)
                    )
                    .glassEffect(.regular.tint(.accentColor.opacity(intensity)), in: .rect(cornerRadius: radius))
            } else {
                content
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: radius)
                                .fill(.ultraThinMaterial)

                            RoundedRectangle(cornerRadius: radius)
                                .fill(
                                    MeshGradient(
                                        width: 3,
                                        height: 3,
                                        points: [
                                            .init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 1, y: 0),
                                            .init(x: 0, y: 0.5), .init(x: 0.5, y: 0.5), .init(x: 1, y: 0.5),
                                            .init(x: 0, y: 1), .init(x: 0.5, y: 1), .init(x: 1, y: 1)
                                        ],
                                        colors: [
                                            .accentColor.opacity(0.1),
                                            .accentColor.opacity(0.05),
                                            .accentColor.opacity(0.1),
                                            .accentColor.opacity(0.05),
                                            .accentColor.opacity(0.02),
                                            .accentColor.opacity(0.05),
                                            .accentColor.opacity(0.1),
                                            .accentColor.opacity(0.05),
                                            .accentColor.opacity(0.1)
                                        ]
                                    )
                                )
                                .opacity(intensity)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    )
            }
        }
    }
}

extension View {
    func liquidGlass(intensity: Double = 0.15, radius: CGFloat = 20) -> some View {
        modifier(LiquidGlassModifier(intensity: intensity, radius: radius))
    }
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    let content: Content
    var intensity: Double = 0.15
    var radius: CGFloat = 20
    var padding: CGFloat = 16
    
    init(intensity: Double = 0.15, radius: CGFloat = 20, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.intensity = intensity
        self.radius = radius
        self.padding = padding
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(padding)
            .liquidGlass(intensity: intensity, radius: radius)
    }
}

// MARK: - Animated Background

struct AnimatedMeshBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0
    
    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 0.1)) { _ in
            MeshGradient(
                width: 4,
                height: 4,
                points: [
                    .init(x: sin(phase) * 0.1, y: cos(phase * 0.7) * 0.1),
                    .init(x: 0.3 + sin(phase * 0.8) * 0.1, y: 0.2 + cos(phase) * 0.1),
                    .init(x: 0.7 + sin(phase * 0.6) * 0.1, y: 0.1 + cos(phase * 0.9) * 0.1),
                    .init(x: 1 + sin(phase * 0.5) * 0.1, y: cos(phase * 0.8) * 0.1),
                    
                    .init(x: 0.1 + sin(phase * 0.7) * 0.1, y: 0.4 + cos(phase * 0.6) * 0.1),
                    .init(x: 0.4 + sin(phase) * 0.1, y: 0.5 + cos(phase * 0.7) * 0.1),
                    .init(x: 0.6 + sin(phase * 0.8) * 0.1, y: 0.4 + cos(phase * 0.5) * 0.1),
                    .init(x: 0.9 + sin(phase * 0.6) * 0.1, y: 0.5 + cos(phase) * 0.1),
                    
                    .init(x: sin(phase * 0.5) * 0.1, y: 0.8 + cos(phase * 0.8) * 0.1),
                    .init(x: 0.3 + sin(phase * 0.9) * 0.1, y: 0.7 + cos(phase * 0.6) * 0.1),
                    .init(x: 0.7 + sin(phase * 0.7) * 0.1, y: 0.8 + cos(phase * 0.9) * 0.1),
                    .init(x: 1 + sin(phase * 0.8) * 0.1, y: 0.7 + cos(phase * 0.5) * 0.1),
                    
                    .init(x: 0.2 + sin(phase) * 0.1, y: 1 + cos(phase * 0.7) * 0.1),
                    .init(x: 0.5 + sin(phase * 0.6) * 0.1, y: 1 + cos(phase * 0.8) * 0.1),
                    .init(x: 0.8 + sin(phase * 0.8) * 0.1, y: 1 + cos(phase * 0.6) * 0.1),
                    .init(x: 1 + sin(phase * 0.5) * 0.1, y: 1 + cos(phase) * 0.1)
                ],
                colors: [
                    .purple.opacity(0.3),
                    .blue.opacity(0.2),
                    .cyan.opacity(0.3),
                    .purple.opacity(0.2),
                    
                    .blue.opacity(0.2),
                    .indigo.opacity(0.15),
                    .blue.opacity(0.2),
                    .cyan.opacity(0.15),
                    
                    .indigo.opacity(0.3),
                    .purple.opacity(0.2),
                    .blue.opacity(0.25),
                    .indigo.opacity(0.2),
                    
                    .purple.opacity(0.2),
                    .blue.opacity(0.15),
                    .cyan.opacity(0.2),
                    .purple.opacity(0.15)
                ]
            )
        }
        .onAppear {
            guard !reduceMotion else {
                phase = .pi * 0.5
                return
            }

            withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ChatSession.self, ChatMessage.self, DownloadedModel.self], inMemory: true)
}
