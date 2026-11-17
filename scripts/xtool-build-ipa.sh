#!/usr/bin/env bash
# Build the unsigned IPA on Linux with xtool, fixed up to match what the CI produces.
#
# xtool builds from the SwiftPM project in .build/xtool-linux, but it does not resolve the
# Xcode build variables in Info.plist ($(PRODUCT_BUNDLE_IDENTIFIER) ...), so Apple refuses to
# sign it ("not a valid identifier for an app"), and it stores the zip uncompressed (3x the size).
# This script resolves those variables from project.yml and recompresses.
#
# usage: scripts/xtool-build-ipa.sh [output.ipa]     (default: .build/IysCodeMovil-xtool.ipa)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$repo/.build/xtool-linux"
out="${1:-$repo/.build/IysCodeMovil-xtool.ipa}"
[ -d "$work" ] || { echo "falta $work (proyecto SwiftPM de xtool)" >&2; exit 1; }

(cd "$work" && xtool dev build -c release --ipa)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unzip -q "$work/xtool/IysCodeMovil.ipa" -d "$tmp"

python3 -I - "$repo/project.yml" "$tmp/Payload/IysCodeMovil.app/Info.plist" <<'PY'
import plistlib, re, sys
yml = open(sys.argv[1]).read()
def setting(key):
    match = re.search(rf'^\s*{key}:\s*"?([^"\n]+)"?\s*$', yml, re.M)
    if not match: sys.exit(f"project.yml sin {key}")
    return match.group(1).strip()
values = {
    "EXECUTABLE_NAME": "IysCodeMovil",
    "PRODUCT_NAME": "IysCodeMovil",
    "PRODUCT_BUNDLE_IDENTIFIER": "dev.iyscode.movil",
    "MARKETING_VERSION": setting("MARKETING_VERSION"),
    "CURRENT_PROJECT_VERSION": setting("CURRENT_PROJECT_VERSION"),
}
path = sys.argv[2]
info = plistlib.load(open(path, "rb"))
def resolve(value):
    if isinstance(value, str):
        return re.sub(r"\$\((\w+)\)", lambda m: values[m.group(1)], value)
    if isinstance(value, list):
        return [resolve(v) for v in value]
    if isinstance(value, dict):
        return {k: resolve(v) for k, v in value.items()}
    return value
info = resolve(info)
info["MinimumOSVersion"] = setting("IPHONEOS_DEPLOYMENT_TARGET")
left = [k for k, v in info.items() if isinstance(v, str) and "$(" in v]
if left: sys.exit(f"variables sin resolver: {left}")
plistlib.dump(info, open(path, "wb"), fmt=plistlib.FMT_BINARY)
print("Info.plist:", info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"])
PY

mkdir -p "$(dirname "$out")"
rm -f "$out"
(cd "$tmp" && zip -qr -9 -X "$out" Payload)
echo "IPA: $out ($(du -h "$out" | cut -f1))"
