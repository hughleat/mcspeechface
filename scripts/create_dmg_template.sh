#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="${1:-$ROOT/native/Assets/McSpeechfaceDMGTemplate.dmg}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mcspeechface-dmg-template.XXXXXX")"
STAGING="$TEMP_ROOT/template-rw.dmg"
MOUNT_POINT="/Volumes/McSpeechface"
PARTIAL="$TEMP_ROOT/McSpeechfaceDMGTemplate.dmg"
PYTHON_PACKAGES="$TEMP_ROOT/python"

cleanup() {
    hdiutil detach -quiet -force "$MOUNT_POINT" >/dev/null 2>&1 || true
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

[[ ! -e "$MOUNT_POINT" ]] || {
    print -u2 "error: $MOUNT_POINT is already in use"
    exit 1
}
hdiutil create -quiet -size 32m -fs HFS+ -volname McSpeechface "$STAGING"
hdiutil attach -quiet "$STAGING"

cp "$ROOT/native/Assets/McSpeechfaceDMGBackground.png" "$MOUNT_POINT/.background.png"
mkdir "$MOUNT_POINT/McSpeechface.app"
ln -s /Applications "$MOUNT_POINT/Applications"
python3 -m pip install --quiet --disable-pip-version-check \
    --target "$PYTHON_PACKAGES" \
    'ds-store==1.3.1' \
    'mac-alias==2.2.2'
PYTHONPATH="$PYTHON_PACKAGES" python3 "$ROOT/scripts/create_dmg_layout.py" "$MOUNT_POINT"

sync
hdiutil detach -quiet "$MOUNT_POINT"
hdiutil convert -quiet "$STAGING" -format UDZO -o "$PARTIAL"
mkdir -p "${OUTPUT:h}"
mv -f "$PARTIAL" "$OUTPUT"
print "Created $OUTPUT"
