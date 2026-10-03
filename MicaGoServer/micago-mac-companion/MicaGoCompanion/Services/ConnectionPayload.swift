import Foundation

/// One connection candidate for the unified payload. `kind` is "lan" or
/// "public" — the client treats the list generically.
struct ConnectionCandidate {
    let kind: String
    let baseUrl: String
    let wsUrl: String
}

/// Builds the unified v4 connection payload (C23). LAN and Public are fully
/// independent: a LAN-only list, a LAN+Public list, and a Public-only list are
/// all valid. The client decides selection (LAN first, Public fallback); there
/// is no LAN-only vs LAN+Public mode. Pure + Foundation-only so it is unit
/// testable without the rest of the app.
///
/// - Returns: a sorted-keys JSON string, or `"{}"` when there are no candidates
///   (the UI shows an empty state in that case rather than copying `{}`).
func unifiedConnectionPayload(
    lan lanCandidates: [ConnectionCandidate],
    publicCandidate: ConnectionCandidate?,
    token: String,
    serverName: String,
    configRevision: String,
    redacted: Bool,
 tlsFingerprint: String = "",
 expiresAt: Int64 = 0
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

    if candidates.isEmpty || tlsFingerprint.count != 64 || expiresAt <= 0 || candidates.contains(where: { !(($0["baseUrl"] as? String)?.hasPrefix("https://") ?? false) || !(($0["wsUrl"] as? String)?.hasPrefix("wss://") ?? false) }) { return "{}" }

    let obj: [String: Any] = [
        "version": 4,
 "tlsFingerprint": tlsFingerprint,
 "expiresAt": expiresAt,
        "pairingCode": redacted ? "<redacted>" : token,
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
