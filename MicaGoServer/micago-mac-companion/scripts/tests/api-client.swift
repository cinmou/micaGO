import Foundation

final class ReplyProtocol: URLProtocol {
    static var reply: (URLRequest) throws -> (Int, String) = { _ in (200, "") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

@main struct APIClientTests {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:3000")!, token: "test-token", session: session)

        ReplyProtocol.reply = { request in
            precondition(request.url?.path == "/api/devices")
            precondition(request.httpMethod == "GET")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            precondition(request.timeoutInterval == 20)
            return (200, #"{"data":[]}"#)
        }
        let devices = try await client.devices()
        precondition(devices.isEmpty)

        let mutation = ChatPreferenceMutation(serverId: "server", mutationId: "mutation", changes: [])
        ReplyProtocol.reply = { request in
            precondition(request.httpMethod == "PATCH")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let sent = try JSONDecoder().decode(ChatPreferenceMutation.self, from: requestBody(request))
            precondition(sent.mutationId == mutation.mutationId)
            return (409, #"{"error":{"code":"conflict","message":"Refresh preferences"}}"#)
        }
        do {
            _ = try await client.patchChatPreferences(mutation)
            preconditionFailure("409 was accepted")
        } catch APIError.status(409, let message) {
            precondition(message == "Refresh preferences")
        }

        ReplyProtocol.reply = { request in
            precondition(request.httpMethod == "DELETE")
            precondition(request.url?.path == "/api/devices/device-1")
            return (204, "")
        }
        try await client.deleteDevice(deviceID: "device-1")

        ReplyProtocol.reply = { _ in (503, "<html>unavailable</html>") }
        do {
            _ = try await client.devices()
            preconditionFailure("503 was accepted")
        } catch APIError.status(503, let message) {
            precondition(message == nil)
        }

        ReplyProtocol.reply = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            precondition(query?.first(where: { $0.name == "q" })?.value == "A&B / 中文")
            return (400, #"{"error":{"code":"bad_request","message":"Bad filter"}}"#)
        }
        do {
            _ = try await client.debugRecentMessages(q: "A&B / 中文")
            preconditionFailure("400 was accepted")
        } catch APIError.status(400, let message) {
            precondition(message == "Bad filter")
        }

        ReplyProtocol.reply = { _ in (207, #"{"data":{"sent":1,"failed":1,"failures":["Device unavailable"]}}"#) }
        let partialPush = await client.testNotifications()
        precondition(partialPush == "Sent 1, failed 1. Device unavailable")
        ReplyProtocol.reply = { _ in (400, #"{"error":{"code":"push_disabled","message":"Push disabled"}}"#) }
        let failedPush = await client.testNotifications()
        precondition(failedPush == "Test push failed: HTTP 400: Push disabled")

        ReplyProtocol.reply = { request in
            precondition(request.httpMethod == "POST" && request.url?.path == "/api/auth/check")
            return (200, #"{"ok":true}"#)
        }
        try await client.checkAuth()
        for status in [401, 403, 500, 503] {
            ReplyProtocol.reply = { _ in (status, #"{"error":{"code":"auth_error","message":"Authentication check failed"}}"#) }
            do {
                try await client.checkAuth()
                preconditionFailure("authentication HTTP failure was accepted")
            } catch APIError.status(let actual, let message) {
                precondition(actual == status && message == "Authentication check failed")
            }
        }
        ReplyProtocol.reply = { _ in (200, #"{"ok":false}"#) }
        do {
            try await client.checkAuth()
            preconditionFailure("negative authentication response was accepted")
        } catch APIError.badResponse {}
        for code in [URLError.timedOut, .cannotConnectToHost, .cancelled] {
            ReplyProtocol.reply = { _ in throw URLError(code) }
            do {
                try await client.checkAuth()
                preconditionFailure("transport failure was accepted")
            } catch let error as URLError {
                precondition(error.code == code)
            }
        }
        ReplyProtocol.reply = { _ in throw URLError(.cannotConnectToHost) }
        let offlinePush = await client.testNotifications()
        precondition(offlinePush == "Test push failed: could not reach server.")

        // A 2xx response with malformed JSON must still fail decoding.
        ReplyProtocol.reply = { _ in (200, "invalid json") }
        do {
            _ = try await client.devices()
            preconditionFailure("invalid JSON was accepted")
        } catch is DecodingError {}

        // Ignored response diagnostics cannot prevent decoding consumed fields.
        ReplyProtocol.reply = { request in
            precondition(request.httpMethod == "POST")
            precondition(request.url?.path == "/api/server/notifications")
            return (200, #"{"implemented":["fcm"],"firestoreSyncEnabled":true}"#)
        }
        let notificationConfig = try await client.setNotificationsConfig(
            enabled: true, provider: "fcm", preview: "sender", fcmEnabled: true,
            fcmProjectID: "project", serviceAccountPath: "", googleServicesPath: "",
            publicURLSync: true)
        precondition(notificationConfig.implemented == ["fcm"] && notificationConfig.firestoreSyncEnabled)

        print("API client request, decoding, HTTP errors, conflict and notification tests passed")
    }
}
