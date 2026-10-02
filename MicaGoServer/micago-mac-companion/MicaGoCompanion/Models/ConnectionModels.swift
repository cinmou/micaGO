import Foundation

// Codable mirrors of GET /api/server/urls and the public-url endpoints (v0.11).
// Local + LAN are always-present derived endpoints; public is an optional extra.

/// Tri-state reachability decoded from JSON `true`, `false`, or `"unknown"`.
enum Reachability: Codable, Hashable {
    case yes
    case no
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = bool ? .yes : .no
            return
        }
        if let string = try? container.decode(String.self) {
            switch string {
            case "true": self = .yes
            case "false": self = .no
            default: self = .unknown
            }
            return
        }
        self = .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .yes: try container.encode(true)
        case .no: try container.encode(false)
        case .unknown: try container.encode("unknown")
        }
    }

    var label: String {
        switch self {
        case .yes: return "reachable"
        case .no: return "unreachable"
        case .unknown: return "unknown"
        }
    }
}

struct ConnectionEndpoint: Codable, Identifiable, Hashable {
    var kind: String
    var label: String
    var baseUrl: String
    var wsUrl: String
    var reachable: Reachability
    var hidden: Bool? = nil

    var id: String { baseUrl }
}

struct PublicEndpoint: Codable {
    var enabled: Bool
    var kind: String?
    var baseUrl: String
    var wsUrl: String
    var reachable: Reachability
    var providerHint: String?
    var verifyTls: Bool
    var lastCheckedAt: Int64?
}

struct ServerURLs: Codable {
    // C25: loopback/local is no longer part of the connection flow — the only
    // client-usable endpoints are LAN and the optional Public.
    var lan: [ConnectionEndpoint]
    var `public`: PublicEndpoint
    var preferredPairingEndpoint: String
    /// C23: a revision that changes whenever the LAN/Public connection settings
    /// change, so paired clients can refresh candidates without rescanning.
    var connectionRevision: String?
}

struct PublicURLCheckResult: Codable {
    var ok: Bool
    var reachable: Bool
    var authOk: Bool
    var status: Int
    var baseUrl: String
    var message: String
}

/// A pairing target the user can pick for the QR code. This is a per-pairing
/// choice, not a global server mode — local/LAN/public all remain active.
struct PairingTarget: Identifiable, Hashable {
    enum Scope: String { case local, lan, `public` }
    var scope: Scope
    var label: String
    var baseUrl: String
    var wsUrl: String

    var id: String { baseUrl }
}
