import SwiftUI
import UniformTypeIdentifiers
import CRaylib.AppleHost

/// Starts the SwiftUI app and calls the game on its rendering thread.
@MainActor
public func runRaylibApp(_ game: @escaping @convention(c) () -> Int32, manualFrameControl: Bool = false) {
    RaylibApp.makeSession = { GameSession(game: game, manualFrameControl: manualFrameControl) }
    RaylibApp.main()
}

@_cdecl("RaylibRunSwiftUIApp")
@MainActor
func raylibRunSwiftUIApp(_ game: @escaping @convention(c) () -> Int32, _ manualFrameControl: Bool) {
    runRaylibApp(game, manualFrameControl: manualFrameControl)
}

@MainActor
private struct RaylibApp: App {
    static var makeSession: (() -> GameSession)?

    var body: some Scene {
#if os(macOS)
        Window(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "raylib", id: "game") {
            GameContent(session: Self.makeSession!())
        }
        .defaultSize(width: 800, height: 450)
#else
        WindowGroup {
            GameContent(session: Self.makeSession!())
        }
#endif
    }
}

@MainActor
private final class GameSession: ObservableObject {
    let host: AppleGameHost
    @Published var failure: String?

    init(game: @escaping @convention(c) () -> Int32, manualFrameControl: Bool) {
        host = AppleGameHost(gameEntry: game, manualFrameControl: manualFrameControl)
    }
}

private struct GameContent: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: GameSession

    init(session: @autoclosure @escaping () -> GameSession) {
        _session = StateObject(wrappedValue: session())
    }

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
