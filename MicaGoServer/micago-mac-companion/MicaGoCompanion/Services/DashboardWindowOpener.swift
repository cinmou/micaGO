import Foundation

/// Coalesces early requests until App registers its SwiftUI window action.
/// Registration must not depend on creating or displaying dashboard content.
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
