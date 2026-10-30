import Foundation

// MARK: unifiedConnectionPayload — LAN and Public are independent (C23r).
func decode(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}
func kinds(_ json: String) -> [String] {
    let obj = decode(json)
    let cands = (obj["candidates"] as? [[String: Any]]) ?? []
    return cands.compactMap { $0["kind"] as? String }
}

let lan = ConnectionCandidate(kind: "lan", baseUrl: "https://192.168.1.5:3001", wsUrl: "wss://192.168.1.5:3001/ws")
let pub = ConnectionCandidate(kind: "public", baseUrl: "https://x.example.com", wsUrl: "wss://x.example.com/ws")

// LAN only — a valid payload with no Public required.
let lanOnly = unifiedConnectionPayload(lan: [lan], publicCandidate: nil,
    pairingCode: "invitation-code", serverName: "Mac", configRevision: "rev1", tlsFingerprint:String(repeating:"a",count:64),expiresAt:1234567890)
precondition(kinds(lanOnly) == ["lan"], "LAN-only payload should have exactly one lan candidate")
precondition((decode(lanOnly)["pairingCode"] as? String) == "invitation-code", "LAN-only payload should carry the invitation code")

// LAN + Public — LAN first, Public second.
let both = unifiedConnectionPayload(lan: [lan], publicCandidate: pub,
    pairingCode: "invitation-code", serverName: "Mac", configRevision: "rev1", tlsFingerprint:String(repeating:"a",count:64),expiresAt:1234567890)
precondition(kinds(both) == ["lan", "public"], "LAN+Public payload should be lan then public")

// Public only — still valid.
let pubOnly = unifiedConnectionPayload(lan: [], publicCandidate: pub,
    pairingCode: "invitation-code", serverName: "Mac", configRevision: "rev1", tlsFingerprint:String(repeating:"a",count:64),expiresAt:1234567890)
precondition(kinds(pubOnly) == ["public"], "Public-only payload should have one public candidate")

// Neither — empty payload (UI shows an empty state instead of copying this).
let none = unifiedConnectionPayload(lan: [], publicCandidate: nil,
    pairingCode: "invitation-code", serverName: "Mac", configRevision: "rev1", tlsFingerprint:String(repeating:"a",count:64),expiresAt:1234567890)
precondition(none == "{}", "no candidates should produce an empty object")

print("unifiedConnectionPayload: all assertions passed")

precondition(decode(lanOnly)["token"] == nil, "administrator token field must never be exported")
precondition((decode(lanOnly)["version"] as? Int) == 4)

let invalid = ConnectionCandidate(kind: "lan", baseUrl: "http://192.168.1.5:3000", wsUrl: "ws://192.168.1.5:3000/ws")
precondition(unifiedConnectionPayload(lan: [invalid], publicCandidate: nil,
    pairingCode: "invitation-code", serverName: "Mac", configRevision: "rev1",
    tlsFingerprint: String(repeating: "a", count: 64), expiresAt: 1234567890) == "{}",
    "insecure candidates cannot produce an invitation")
precondition(unifiedConnectionPayload(lan: [lan], publicCandidate: nil,
    pairingCode: "invitation-code", serverName: "Mac", configRevision: "rev1",
    tlsFingerprint: "", expiresAt: 1234567890) == "{}",
    "a missing certificate fingerprint cannot produce an invitation")
precondition(unifiedConnectionPayload(lan: [lan], publicCandidate: nil,
    pairingCode: "invitation-code", serverName: "Mac", configRevision: "rev1",
    tlsFingerprint: String(repeating: "a", count: 64), expiresAt: 0) == "{}",
    "an invitation must carry an expiry")
let candidates = decode(both)["candidates"] as! [[String: Any]]
precondition(candidates.map { $0["priority"] as! Int } == [1, 2])
precondition(decode(both)["configRevision"] as? String == "rev1")
print("secure invitation validation tests passed")
