import Foundation

/// Merge remote settings field by field, preserving only actual unsaved edits.
struct NotificationFormValues: Equatable {
    var enabled: Bool
    var preview: String
    var fcmEnabled: Bool
    var projectID: String
    var publicURLSync: Bool

    func merging(server: Self, previousServer: Self?) -> Self {
        guard let previousServer else { return server }
        var merged = self
        if enabled == previousServer.enabled { merged.enabled = server.enabled }
        if preview == previousServer.preview { merged.preview = server.preview }
        if fcmEnabled == previousServer.fcmEnabled { merged.fcmEnabled = server.fcmEnabled }
        if projectID == previousServer.projectID { merged.projectID = server.projectID }
        if publicURLSync == previousServer.publicURLSync { merged.publicURLSync = server.publicURLSync }
        return merged
    }
}

// POST /api/server/notifications response (v0.12). Mirrors the server's
// notification status plus two flags. Never contains secrets.
struct NotificationsConfigResponse: Codable {
    var enabled: Bool
    var provider: String
    var preview: String
    var providers: [String]
    var implemented: [String]
    var stub: [String]
    var serviceAccountPathSet: Bool
    var googleServicesPathSet: Bool
    var firestoreSyncEnabled: Bool
}

struct TestNotificationsEnvelope: Codable {
    var data: TestNotificationsResult
}

struct TestNotificationsResult: Codable {
    var sent: Int
    var failed: Int
    var failures: [String]?
}

// Standard server error envelope: { "error": { "code": ..., "message": ... } }.
struct ErrorEnvelope: Codable {
    struct APIErrorBody: Codable {
        var code: String
        var message: String
    }
    var error: APIErrorBody
}
