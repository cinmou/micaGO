import Foundation

/// One connection candidate for the unified payload. `kind` is "lan" or
/// "public" — the client treats the list generically.
struct ConnectionCandidate {
    let kind: String
    let baseUrl: String
    let wsUrl: String
}

/// Encodes the visible LAN routes and optional public route in a v4 invitation.
/// Invalid or empty candidates produce "{}", which the UI treats as unavailable.
func unifiedConnectionPayload(
    lan lanCandidates: [ConnectionCandidate],
    publicCandidate: ConnectionCandidate?,
    pairingCode: String,
    serverName: String,
    configRevision: String,
    tlsFingerprint: String,
    expiresAt: Int64
) -> String {
    var candidates: [[String: Any]] = []
    var priority = 1
    func add(_ c: ConnectionCandidate) {
        candidates.append([
            "kind": c.kind,
            "baseUrl": c.baseUrl,
            "wsUrl": c.wsUrl,
            "priority": priority,
        ])
        priority += 1
    }
    // LAN first (every LAN endpoint), then Public as the optional fallback.
    for c in lanCandidates { add(c) }
    if let publicCandidate { add(publicCandidate) }

    guard !candidates.isEmpty, tlsFingerprint.count == 64, expiresAt > 0,
          candidates.allSatisfy({
              ($0["baseUrl"] as? String)?.hasPrefix("https://") == true &&
              ($0["wsUrl"] as? String)?.hasPrefix("wss://") == true
          }) else { return "{}" }

    let obj: [String: Any] = [
        "version": 4,
        "tlsFingerprint": tlsFingerprint,
        "expiresAt": expiresAt,
        "pairingCode": pairingCode,
        "serverName": serverName,
        "configRevision": configRevision,
        "candidates": candidates,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return json
}
