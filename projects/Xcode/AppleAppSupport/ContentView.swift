import SwiftUI
import UniformTypeIdentifiers

@_cdecl("RaylibRunSwiftUIApp")
func raylibRunSwiftUIApp() {
    RaylibApp.main()
}

private struct RaylibApp: App {
    var body: some Scene {
#if os(macOS)
        Window(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "raylib", id: "game") {
            GameContent()
        }
        .defaultSize(width: 800, height: 450)
#else
        WindowGroup {
            GameContent()
        }
#endif
    }
}

@MainActor
private final class GameSession: ObservableObject {
    let host = AppleGameHost()
    @Published var failure: String?
}

private struct GameContent: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = GameSession()

    var body: some View {
        if let message = session.failure ?? Bundle.main.object(forInfoDictionaryKey: "RaylibUnavailable") as? String,
           !message.isEmpty {
            Text(message)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            ContentView(host: session.host, active: scenePhase == .active, reportError: { session.failure = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
#if !os(tvOS)
                .dropDestination(for: URL.self) { urls, _ in
                    for url in urls where url.isFileURL { session.host.dropFile(url) }
                    return urls.contains(where: \.isFileURL)
                }
#endif
        }
    }
}

private struct ContentView {
    let host: AppleGameHost
    let active: Bool
    let reportError: (String) -> Void

    func makeCoordinator() -> AppleGameHost { host }

    private func proposedSize(_ proposal: ProposedViewSize) -> CGSize? {
        guard
            let width = proposal.width,
            width.isFinite,
            let height = proposal.height,
            height.isFinite
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

#if os(macOS)
extension ContentView: NSViewRepresentable {
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposedSize(proposal)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.reportError = reportError
        return context.coordinator.makeView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.reportError = reportError
        context.coordinator.setSceneActive(active)
    }

    static func dismantleNSView(_ view: NSView, coordinator: AppleGameHost) {
        coordinator.stop()
    }
}
#else
extension ContentView: UIViewControllerRepresentable {
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIViewController, context: Context) -> CGSize? {
        proposedSize(proposal)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        context.coordinator.reportError = reportError
        return context.coordinator.makeViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.reportError = reportError
        context.coordinator.setSceneActive(active)
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: AppleGameHost) {
        coordinator.stop()
    }
}
#endif
