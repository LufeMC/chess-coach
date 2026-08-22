import SwiftUI

@main
struct ChessCoachApp: App {

    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if canImport(UIKit)
            // Navigation titles in the same rounded-heavy voice as everything
            // else. SwiftUI exposes no font hook for bar titles, so this is the
            // platform's own seam for it.
            let large = UIFont.systemFont(ofSize: 34, weight: .heavy)
            let inline = UIFont.systemFont(ofSize: 17, weight: .heavy)
            UINavigationBar.appearance().largeTitleTextAttributes = [
                .font: UIFont(
                    descriptor: large.fontDescriptor.withDesign(.rounded) ?? large.fontDescriptor,
                    size: 34
                )
            ]
            UINavigationBar.appearance().titleTextAttributes = [
                .font: UIFont(
                    descriptor: inline.fontDescriptor.withDesign(.rounded) ?? inline.fontDescriptor,
                    size: 17
                )
            ]
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Macaw blue for everything the button styles don't already
                // paint: tab selection, links, toolbar glyphs. Green stays
                // reserved for the primary action.
                .tint(Palette.blue.dynamic)
                .task {
                    await model.boot()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // The engine must be drained before suspension: iOS terminates
                // processes holding CPU in the background, and a search
                // interrupted that way leaves the UCI loop waiting for a
                // `bestmove` that never arrives, deadlocking the next launch.
                //
                // Called straight through rather than from a `Task`: the model
                // takes a background-execution assertion synchronously here, and
                // an assertion taken after a hop can be taken after the process
                // has already been frozen.
                model.handleBackgrounding()
            case .active:
                // The other half of the same story, and the half that was
                // missing: backgrounding pauses whatever pass was running, and
                // nothing used to ask for it again until the next launch or the
                // next finished game.
                model.handleForegrounding()
            case .inactive:
                // The doorway between the two — a notification shade, the app
                // switcher, an incoming call — and not a state either side of
                // this should act on. Draining here would fire on every
                // half-swipe.
                break
            @unknown default:
                break
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
