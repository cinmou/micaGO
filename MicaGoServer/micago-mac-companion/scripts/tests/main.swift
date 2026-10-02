// C23 standalone tests (no XCTest target exists). Run via:
//   swiftc MicaGoCompanion/Services/VersionFormat.swift \
//          MicaGoCompanion/Services/ConnectionPayload.swift \
//          scripts/tests/main.swift -o /tmp/vftest && /tmp/vftest
import Foundation

// MARK: displayVersion — exactly one leading "v".
func expect(_ input: String, _ want: String) {
    let got = displayVersion(input)
    precondition(got == want, "displayVersion(\"\(input)\") = \"\(got)\", want \"\(want)\"")
}
expect("v0.15.0", "v0.15.0")
expect("0.15.0", "v0.15.0")
expect("vv0.15.0", "v0.15.0")   // collapses the old "vv" bug
expect("  V0.15.0 ", "v0.15.0") // trims + lowercases the marker
expect("", "v?")
print("displayVersion: all assertions passed")

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
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: false,tlsFingerprint:String(repeating:"a",count:64),expiresAt:1234567890)
precondition(kinds(lanOnly) == ["lan"], "LAN-only payload should have exactly one lan candidate")
precondition((decode(lanOnly)["pairingCode"] as? String) == "tok", "LAN-only payload should carry the token")

// LAN + Public — LAN first, Public second.
let both = unifiedConnectionPayload(lan: [lan], publicCandidate: pub,
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: false,tlsFingerprint:String(repeating:"a",count:64),expiresAt:1234567890)
precondition(kinds(both) == ["lan", "public"], "LAN+Public payload should be lan then public")

// Public only — still valid.
let pubOnly = unifiedConnectionPayload(lan: [], publicCandidate: pub,
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: false,tlsFingerprint:String(repeating:"a",count:64),expiresAt:1234567890)
precondition(kinds(pubOnly) == ["public"], "Public-only payload should have one public candidate")

// Neither — empty payload (UI shows an empty state instead of copying this).
let none = unifiedConnectionPayload(lan: [], publicCandidate: nil,
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: false,tlsFingerprint:String(repeating:"a",count:64),expiresAt:1234567890)
precondition(none == "{}", "no candidates should produce an empty object")

// Redaction hides the token.
let red = unifiedConnectionPayload(lan: [lan], publicCandidate: nil,
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: true,tlsFingerprint:String(repeating:"a",count:64),expiresAt:1234567890)
precondition((decode(red)["pairingCode"] as? String) == "<redacted>", "redacted payload must hide the token")

print("unifiedConnectionPayload: all assertions passed")

precondition(decode(lanOnly)["token"] == nil, "administrator token field must never be exported")
precondition((decode(lanOnly)["version"] as? Int) == 4)
