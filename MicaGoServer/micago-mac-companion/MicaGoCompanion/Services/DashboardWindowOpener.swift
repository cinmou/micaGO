import Foundation

/// Coalesces requests arriving before the SwiftUI scene is ready. Every open
/// uses that scene, including the first menu-bar open after a silent launch.
@MainActor
final class DashboardWindowOpener {
    static let shared = DashboardWindowOpener()
    private var open: (() -> Void)?
    private var pending = false

    func install(_ action: @escaping () -> Void) {
        open = action
        if pending {
            pending = false
            action()
        }
    }

    func requestOpen() {
        guard let open else {
            pending = true
            return
        }
        open()
    }
}
