# Windows connection protocol

Windows pairing accepts Companion v4 JSON only. Older parsing fixtures remain for compatibility checks, but legacy payloads cannot activate a connection. Create a fresh five-minute invitation on the Mac when migrating.

```json
{
  "version": 4,
  "pairingCode": "<single-use invitation>",
  "tlsFingerprint": "<SHA-256 certificate fingerprint>",
  "candidates": [
    {"kind": "lan", "baseUrl": "https://192.168.1.3:3001", "wsUrl": "wss://192.168.1.3:3001/ws"}
  ]
}
```

## Input and redemption

Pasting JSON, optional camera scanning, and importing a QR image all use `PairingPayloadParser`. QR recognition uses ZXing.Net; native camera frames use `MediaCapture` and `MediaFrameReader`. Camera access starts only after selecting Scan and stops on completion or cancellation. A PC without a camera can paste JSON or choose an image.

Scanning fills the JSON input. Selecting Connect checks Credential Manager persistence before contacting the redemption endpoint. The client verifies an HTTPS health endpoint, then sends `POST /api/pairing/redeem` exactly once. An uncertain redemption result requires a fresh invitation. The issued device credential is saved before route activation so a later activation timeout can be recovered through saved-profile restore.

## Transport and persistence

LAN HTTPS/WSS pins the persisted SHA-256 certificate fingerprint. Public HTTPS/WSS uses system certificate trust. There is no plaintext fallback or redirect-based downgrade. Health and authentication probes select an available route; authenticated requests and WebSocket handshakes use `Authorization: Bearer …`, never URL tokens.

`%LOCALAPPDATA%\micaGO\connection-profile.json` stores endpoint configuration, fingerprint and device identity, without the credential. The credential is saved only as `micaGO.Windows/server-token` in Windows Credential Manager. Endpoint refresh retains the device identity and trust policy.

## Rejected credentials

An authenticated HTTP 401 permanently rejects that API instance. Parallel or late successes are withheld; further requests, device presence and reconnect stop. A stale API instance cannot reject a newer active connection. Ordinary 403 action permission failures do not revoke the credential.

The application closes the chat/media surface, removes the saved connection, clears cached history/media, and presents a native re-pairing dialog. It does not leave a persistent top banner or replace rejection with timeout wording. Preference outboxes remain in their existing server scope. Pending cleanup is recorded in local settings and completed before another pairing attempt.

## Validation

`dotnet run --project tests/micaGO.Core.ContractTests` covers secure payloads, pinning, QR decoding, terminal rejection, late responses, media cache access, Credential Manager preflight isolation, and route-scoped manual unread replay. Native camera capture, permission refusal, XAML activation and dialog/window transitions require a Windows build and device smoke test.
