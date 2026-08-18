import SwiftUI

@main
struct ChessCoachApp: App {

    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    await model.boot()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // The engine must be drained before suspension: iOS terminates
            // processes holding CPU in the background, and a search interrupted
            // that way leaves the UCI loop waiting for a `bestmove` that never
            // arrives, deadlocking the next launch.
            if phase == .background {
                Task { await model.handleBackgrounding() }
            }
        }
        #if os(macOS)
            .defaultSize(width: 1180, height: 820)
            .commands {
                ReviewCommands()
            }
        #endif
    }
}

#if os(macOS)
/// Keyboard navigation for reviewing games — the Mac is the review surface, so
/// stepping through moves needs to work without touching the mouse.
struct ReviewCommands: Commands {
    var body: some Commands {
        CommandMenu("Review") {
            Button("Previous Move") {
                NotificationCenter.default.post(name: .reviewStepBackward, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Next Move") {
                NotificationCenter.default.post(name: .reviewStepForward, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Divider()

            Button("Flip Board") {
                NotificationCenter.default.post(name: .reviewFlipBoard, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])
        }
    }
}

extension Notification.Name {
    static let reviewStepForward = Notification.Name("reviewStepForward")
    static let reviewStepBackward = Notification.Name("reviewStepBackward")
    static let reviewFlipBoard = Notification.Name("reviewFlipBoard")
}
#endif
