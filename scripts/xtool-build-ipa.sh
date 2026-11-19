#!/usr/bin/env bash
# Build from the current worktree on Linux. See scripts/xtool/README.md.
# usage: scripts/xtool-build-ipa.sh [output.ipa]
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$repo/.build/xtool-device"
legacy="$repo/.build/xtool-linux"
if [[ -f "$legacy/Package.swift" && ! -d "$work/inputs" && "${ISYCODE_XTOOL_BOOTSTRAP:-0}" != 1 ]]; then
    work="$legacy"
fi
out="${1:-$repo/.build/IysCodeMovil-xtool.ipa}"
out="$(realpath -m "$out")"
mkdir -p "$work"
exec 9>"$work/build.lock"
flock 9
if [[ "$work" != "$legacy" ]]; then
    python3 "$repo/scripts/xtool/prepare.py"
fi

(cd "$work" && xtool dev build -c release --ipa)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unzip -q "$work/xtool/IysCodeMovil.ipa" -d "$tmp"

python3 -I - "$repo/project.yml" "$tmp/Payload/IysCodeMovil.app/Info.plist" "$work/inputs/icons.plist" <<'PY'
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
from pathlib import Path
icons = Path(sys.argv[3])
if icons.is_file():
    info.update(plistlib.loads(icons.read_bytes()))
info["MinimumOSVersion"] = setting("IPHONEOS_DEPLOYMENT_TARGET")
left = [k for k, v in info.items() if isinstance(v, str) and "$(" in v]
if left: sys.exit(f"variables sin resolver: {left}")
plistlib.dump(info, open(path, "wb"), fmt=plistlib.FMT_BINARY)
print("Info.plist:", info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"])
PY

app="$tmp/Payload/IysCodeMovil.app"
if [[ -d "$work/inputs/resources" ]]; then
    cp -a "$work/inputs/resources/." "$app/"
    test -s "$app/Assets.car"
fi
mkdir -p "$app/LocalPacks"
cp -a "$repo/LocalPacks/." "$app/LocalPacks/"
test -s "$app/IysCodeMovil"
test -s "$app/Frameworks/llama.framework/llama"
mkdir -p "$(dirname "$out")"
(cd "$tmp" && zip -qr -9 -X result.ipa Payload)
unzip -tq "$tmp/result.ipa"
mv "$tmp/result.ipa" "$out"
echo "IPA: $out ($(du -h "$out" | cut -f1))"
