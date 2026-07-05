import Foundation

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
