import Foundation
import Observation
import SwiftUI

/// Root application state and the single place services are constructed.
///
/// Everything below this is a value type or an actor; this is the one piece of
/// long-lived observable state the views bind to.
@Observable
@MainActor
final class AppModel {

    enum BootState: Equatable {
        case idle
        case booting
        case ready
        case failed(String)
    }

    private(set) var bootState: BootState = .idle

    /// Set once the engine reports its measured throughput, so the UI can show
    /// honest analysis-time estimates instead of a guess.
    private(set) var deviceProfile: EngineService.DeviceProfile = .unknown

    /// Navigation target, shared by the Today screen's CTA and any deep link.
    var route: Route?

    let engineService = EngineService()

    enum Route: Hashable {
        case play
        case review(gameID: UUID)
        case moment(momentID: UUID)
        case train
        case profile
        case settings
    }

    func boot() async {
        guard bootState == .idle else { return }
        bootState = .booting

        do {
            try await engineService.boot(networks: .standard())
            deviceProfile = await engineService.deviceProfile
            bootState = .ready
        } catch {
            // A missing network is the expected first-run failure; surface it
            // rather than silently running without an engine.
            bootState = .failed(String(describing: error))
        }
    }

    func handleBackgrounding() async {
        await engineService.suspendForBackground()
    }

    func navigate(to route: Route) {
        self.route = route
    }
}
