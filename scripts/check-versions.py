#!/usr/bin/env python3
"""Reject release metadata drift before packaging any platform."""
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]


def values(path, pattern):
    matches = re.findall(pattern, (root / path).read_text())
    if not matches:
        raise SystemExit(f"No version found in {path}")
    return set(matches)


pubspec = values("MicaGoFlutterClient/pubspec.yaml", r"(?m)^version:\s*(\S+)").pop()
version, build = pubspec.split("+")
sources = {
    "MicaGoServer/micago-server/internal/version/version.go": r'var Version = "v([^"]+)"',
    "MicaGoFlutterClient/lib/core/network/device_identity.dart": r"kAppVersion = '([^']+)'",
    "MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj/project.pbxproj": r"MARKETING_VERSION = ([^;]+);",
    "MicaGoServer/micago-mac-companion/scripts/package-dmg.sh": r'VERSION="\$\{VERSION:-([^}]+)\}"',
    "MicaGoWindowsClient/Directory.Build.props": r"<MicaGoVersion>([^<]+)</MicaGoVersion>",
}
for path, pattern in sources.items():
    actual = values(path, pattern)
    if actual != {version}:
        raise SystemExit(f"{path}: expected {version}, got {sorted(actual)}")
project = "MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj/project.pbxproj"
if values(project, r"CURRENT_PROJECT_VERSION = ([^;]+);") != {build}:
    raise SystemExit(f"{project}: build number must match {build}")
print(f"Versions agree: {version}+{build}")
