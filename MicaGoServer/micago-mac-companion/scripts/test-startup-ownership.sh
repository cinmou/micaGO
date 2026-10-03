#!/bin/sh
# Focused regression tests for C18 backend/tunnel startup ownership.
set -eu
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'EOF'
import Foundation

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("ok   \(name)")
    } else {
        print("FAIL \(name)")
        exitCode = 1
    }
}

var exitCode: Int32 = 0

let publicConfig = MicaConfig(
    addr: "0.0.0.0:3000",
    token: "tok",
    publicURL: "https://micago.example.com",
    configPath: "/tmp/config.yaml"
)
check(
    ConfigReader.baseURL(for: publicConfig)?.absoluteString == "http://127.0.0.1:3000",
    "Companion control API ignores public/tunnel URL"
)
check(
    ConfigReader.controlAddress("0.0.0.0:3000") == "127.0.0.1:3000",
    "0.0.0.0 bind maps to loopback for local control"
)
check(
    ConfigReader.controlAddress("[::]:3000") == "127.0.0.1:3000",
    "IPv6 any bind maps to loopback for local control"
)
check(
    ConfigReader.controlAddress("192.168.1.5:3000") == "127.0.0.1:3000",
    "specific LAN bind still uses local control"
)

// C18 crash regression: Go's host-less listen syntax must never produce a
// malformed "http://:3000" control URL (the ":3000/api/health" bug).
check(
    ConfigReader.controlAddress(":3000") == "127.0.0.1:3000",
    "host-less Go listen address ':3000' maps to loopback"
)
check(
    ConfigReader.baseURL(for: MicaConfig(addr: ":3000", token: "t", publicURL: nil, configPath: ""))?
        .absoluteString == "http://127.0.0.1:3000",
    "baseURL for ':3000' has a host (no ':3000/api/health' URLs)"
)
check(
    ConfigReader.controlAddress("") == "127.0.0.1:3000",
    "empty addr falls back to loopback:3000"
)
check(
    ConfigReader.controlAddress("::") == "127.0.0.1:3000",
    "bare IPv6 any '::' maps to loopback with default port"
)
check(
    ConfigReader.controlHostPort("[::1]:8080") == ("127.0.0.1", 8080),
    "bracketed IPv6 bind uses local control and keeps port"
)
check(
    ConfigReader.controlAddress("192.168.1.5") == "127.0.0.1:3000",
    "missing port defaults to 3000"
)
check(
    ConfigReader.controlAddress("0.0.0.0:99999") == "127.0.0.1:3000",
    "out-of-range port falls back to 3000"
)
// The control URL must ALWAYS have a non-empty host, whatever the input —
// covering Client Setup rendering with backend/tunnel stopped and no LAN.
for weird in ["", ":", ":3000", "::", "0.0.0.0:", "[::]:3000", "  "] {
    let url = ConfigReader.baseURL(for: MicaConfig(addr: weird, token: "t", publicURL: nil, configPath: ""))
    check(url?.host?.isEmpty == false, "baseURL('\(weird)') always has a host")
}

exit(exitCode)
EOF

xcrun swiftc -o "$TMP/startup_test" MicaGoCompanion/Services/ConfigReader.swift "$TMP/main.swift"
"$TMP/startup_test"

if grep -R "TunnelController\\|TunnelAutopilot\\|cloudflared" MicaGoCompanion/Services/BackendController.swift >/dev/null; then
  echo "FAIL BackendController must not reference tunnel/cloudflared"
  exit 1
fi
echo "ok   BackendController has no tunnel references"

echo "startup ownership tests passed"
