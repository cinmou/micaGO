#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/fixture.swift" <<'SWIFT'
import Foundation
import CryptoKit
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let payload = Data("signed update fixture".utf8)
let archive = dir.appendingPathComponent("fixture.dmg")
try payload.write(to: archive)
let info: [String: Any] = ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(), "CFBundleVersion": "87", "CFBundleShortVersionString": "0.87.0"]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: dir.appendingPathComponent("Info.plist"))
let signature = try key.signature(for: payload).base64EncodedString()
let xml = """
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>87</sparkle:version><sparkle:shortVersionString>0.87.0</sparkle:shortVersionString><enclosure url="https://github.com/cinmou/MicaGo/releases/download/v0.87.0/fixture.dmg" length="\(payload.count)" sparkle:edSignature="\(signature)" /></item></channel></rss>
"""
try xml.write(to: dir.appendingPathComponent("appcast.xml"), atomically: true, encoding: .utf8)
SWIFT
xcrun swift "$TEST_DIR/fixture.swift" "$TEST_DIR"
xcrun swiftc "$SCRIPT_DIR/validate-update.swift" -o "$TEST_DIR/validate"
"$TEST_DIR/validate" "$TEST_DIR/appcast.xml" "$TEST_DIR/fixture.dmg" "$TEST_DIR/Info.plist" 0.87.0
python3 - "$TEST_DIR" <<'PY'
from pathlib import Path
import sys, subprocess
p=Path(sys.argv[1]); original=(p/'appcast.xml').read_text(); payload=(p/'fixture.dmg').read_bytes()
def rejects(name, xml=original, data=payload):
 (p/'appcast.xml').write_text(xml);(p/'fixture.dmg').write_bytes(data)
 result=subprocess.run([str(p/'validate'),str(p/'appcast.xml'),str(p/'fixture.dmg'),str(p/'Info.plist'),'0.87.0'],capture_output=True)
 assert result.returncode!=0,name
 print('PASS rejects '+name)
rejects('wrong download host',original.replace('github.com','example.com'))
rejects('wrong appcast build',original.replace('>87<','>86<'))
rejects('wrong release version',original.replace('>0.87.0<','>0.88.0<'))
rejects('archive length mismatch',data=payload+b'x')
rejects('same-size modified archive',data=b'X'+payload[1:])
rejects('missing signature',original.replace('sparkle:edSignature','ignoredSignature'))
rejects('malformed feed','<rss>')
PY
