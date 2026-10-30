import Foundation
import ServiceManagement

/// Login item registration through macOS ServiceManagement.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval in System Settings"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
