#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
MACOS_14_WORKFLOW="$ROOT/.github/workflows/macos-14.yml"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"

zsh -n \
    "$ROOT/scripts/build_native_app.sh" \
    "$ROOT/scripts/create_dmg_template.sh" \
    "$ROOT/scripts/setup_local_signing.sh" \
    "$ROOT/scripts/test_coreml_production.sh" \
    "$ROOT/scripts/test_sponsorship_builds.sh" \
    "$ROOT/scripts/smoke_release.sh"
plutil -lint "$ROOT/native/LoginItemInfo.plist" >/dev/null
bash -n "$ROOT/scripts/release_metadata.sh" "$ROOT/scripts/run_ci_acceptance.sh"
PYTHONPYCACHEPREFIX="$ROOT/.build/python-cache" \
    python3 -m py_compile "$ROOT/scripts/create_dmg_layout.py"
rg -q -F 'native release unexpectedly contains Python source' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'native release unexpectedly contains MLX' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'release unexpectedly contains model weights' "$ROOT/scripts/smoke_release.sh"
rg -q -F -- "-o -name '*.gguf'" "$ROOT/scripts/smoke_release.sh"
rg -q -F 'bundle icon is missing' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'vtool -show-build' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'lipo -archs' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'expected-entitlements.plist' "$ROOT/scripts/smoke_release.sh"
rg -q -F -- '--expected-entitlements "$ENTITLEMENTS"' "$ROOT/scripts/build_native_app.sh"
rg -q -F -- '--expected-sponsorship "$sponsorship_value"' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'MCSPEECHFACE_SPONSORSHIP_ENABLED' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'APP="$OUTPUT_DIR/McSpeechface.app"' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'cp "$ROOT/.build/release/McSpeechface" "$APP/Contents/MacOS/McSpeechface"' \
    "$ROOT/scripts/build_native_app.sh"
rg -q -F 'Contents/Library/LoginItems/McSpeechfaceLoginItem.app' \
    "$ROOT/scripts/build_native_app.sh"
rg -q -F 'launch-at-login helper app is missing' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'native/login_item_launcher.c' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'launch-at-login helper is missing or not executable' \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F 'launch-at-login helper resolves the wrong app bundle' \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F 'execl("/usr/bin/open", "open", "-g", resolved' \
    "$ROOT/native/login_item_launcher.c"
rg -q -F '.executable(name: "McSpeechfaceCommand", targets: ["McSpeechfaceCLI"])' "$ROOT/Package.swift"
rg -q -F '.build/release/McSpeechfaceCommand" "$APP/Contents/Helpers/mcspeechface"' \
    "$ROOT/scripts/build_native_app.sh"
rg -q -F 'command-line helper was replaced by the GUI executable' \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F 'local transcript editing runtime could not start' \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F 'Contents/Helpers/llama/mcspeechface-llama-server' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'local transcript editing runtime has non-system dependencies' \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F -- '--print-build-features' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'executable and bundle sponsorship states do not match' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'sponsorship-disabled executable contains a Sponsors URL' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'McSpeechface-notarization-submission.zip' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'archive="$ARCHIVE_DIR/McSpeechface-$VERSION-$BUILD_NUMBER-macOS-arm64.dmg"' \
    "$ROOT/scripts/build_native_app.sh"
rg -q -F 'archive="$ARCHIVE_DIR/McSpeechface-$VERSION-$BUILD_NUMBER-macOS-arm64$suffix.zip"' \
    "$ROOT/scripts/build_native_app.sh"
rg -q -F 'print "McSpeechface build complete"' "$ROOT/scripts/build_native_app.sh"
archive_cleanup_line="$(rg -n -F 'rm -f "$archive" "$archive.sha256" "$archive.partial"' "$ROOT/scripts/build_native_app.sh" | tail -1 | cut -d: -f1)"
notarization_line="$(rg -n -F 'xcrun notarytool submit' "$ROOT/scripts/build_native_app.sh" | head -1 | cut -d: -f1)"
smoke_line="$(rg -n -F 'smoke_release.sh" --app "$APP" --notarized' "$ROOT/scripts/build_native_app.sh" | head -1 | cut -d: -f1)"
[[ "$archive_cleanup_line" -lt "$notarization_line" ]]
[[ "$archive_cleanup_line" -lt "$smoke_line" ]]
rg -q -F 'mv -f "$partial" "$archive"' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'McSpeechfaceDMGTemplate.dmg' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'DMG template volume must be named McSpeechface' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'DMG template contains the obsolete app bundle' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'DMG contains the obsolete app bundle' "$ROOT/scripts/build_native_app.sh"
rg -q -F '747f59ae83a5bafc487f3a5c22591c8a9b73cec946ff115da72c99442f7ba568' \
    "$ROOT/scripts/build_native_app.sh"
rg -q -F "'ds-store==1.3.1'" "$ROOT/scripts/create_dmg_template.sh"
rg -q -F "'mac-alias==2.2.2'" "$ROOT/scripts/create_dmg_template.sh"
rg -q -F 'McSpeechface.app' "$ROOT/scripts/create_dmg_layout.py"
rg -q -F 'hdiutil convert -quiet' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'hdiutil resize -quiet -size 128m' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'hdiutil detach -quiet -force' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'could not detach stale DMG mount' "$ROOT/scripts/build_native_app.sh"
rg -q -F '{{200, 120}, {660, 420}}' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'background does not match its source asset' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'hdiutil verify "$DMG_PARTIAL"' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'hdiutil attach -quiet -readonly -nobrowse' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'expected Finder layout' "$ROOT/scripts/build_native_app.sh"
rg -q -F '"$ROOT/scripts/build_native_app.sh" dmg' "$ROOT/scripts/test_all.sh"
rg -q -F '"$ROOT/scripts/test_coreml_production.sh"' "$ROOT/scripts/test_all.sh"
rg -q -F '"$ROOT/scripts/test_sponsorship_builds.sh"' "$ROOT/scripts/test_all.sh"
rg -q -F 'FluidAudio-Apache-2.0.txt' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'Argmax-OSS-MIT.txt' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'Argmax-OSS-NOTICES.txt' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'THIRD_PARTY_NOTICES.md' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'LLAMA_RUNTIME_RELEASE="b10687"' "$ROOT/scripts/build_native_app.sh"
rg -q -F '03798972d2a6fe4a77288e897517f3a770d0057b9bc58e46cbe3eebc2b166b0f' \
    "$ROOT/scripts/build_native_app.sh"
rg -q -F 'build ${LLAMA_RUNTIME_RELEASE#b}' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'commit $LLAMA_RUNTIME_COMMIT' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'CMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"' \
    "$ROOT/scripts/build_native_app.sh"
rg -q -F 'BUILD_SHARED_LIBS=OFF' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'LLAMA_OPENSSL=OFF' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'llama.cpp-MIT.txt' "$ROOT/scripts/build_native_app.sh"
rg -q -F -- '--app "$DMG_MOUNT_POINT/McSpeechface.app"' "$ROOT/scripts/build_native_app.sh"
rg -q -F -- '--ad-hoc-only' "$ROOT/scripts/build_native_app.sh"
rg -q -F "'^Signature=adhoc$'" "$ROOT/scripts/smoke_release.sh"
if rg -q -F -- '--update' "$ROOT/scripts/build_native_app.sh"; then
    print -u2 "release build still rewrites its deployment target"
    exit 1
fi
plutil -lint "$ROOT/native/Info.plist" "$ROOT/native/McSpeechface.entitlements" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ROOT/native/Info.plist")" == "McSpeechface" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/native/Info.plist")" == "McSpeechface" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/native/Info.plist")" == "com.hughleat.mcspeechface" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ROOT/native/Info.plist")" == "McSpeechface" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$ROOT/native/Info.plist")" == "mcspeechface" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ROOT/native/McSpeechface.entitlements")" == "true" ]]
rg -q -F '.appendingPathComponent("McSpeechface", isDirectory: true)' \
    "$ROOT/Sources/McSpeechface/AppPaths.swift"
rg -q -F 'URL(fileURLWithPath: "/usr/local/bin/mcspeechface")' \
    "$ROOT/Sources/McSpeechface/CommandLineToolInstaller.swift"
rg -q -F 'private static let privateDirectoryName = "McSpeechface"' \
    "$ROOT/Sources/McSpeechfaceIPC/CommandSocketPath.swift"
rg -q -F 'environment["MCSPEECHFACE_COMMAND_SOCKET"]' \
    "$ROOT/Sources/McSpeechfaceIPC/CommandSocketPath.swift"
rg -q -F 'release app bundle must be McSpeechface.app' \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F 'bundle display name must be McSpeechface' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'bundle identifier must be com.hughleat.mcspeechface' \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F 'bundle executable must be McSpeechface' \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F 'expected_cli_version="McSpeechface $actual_version"' \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F 'McSpeechface release smoke check passed' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'runs-on: macos-14' "$MACOS_14_WORKFLOW"
rg -q -F 'name: McSpeechface macOS 14 acceptance' "$MACOS_14_WORKFLOW"
rg -q -F 'name: McSpeechface on Apple Silicon macOS 14' "$MACOS_14_WORKFLOW"
rg -q -F 'name: McSpeechface-macOS-arm64' "$MACOS_14_WORKFLOW"
rg -q -F 'actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' "$MACOS_14_WORKFLOW"
rg -q -F 'persist-credentials: false' "$MACOS_14_WORKFLOW"
rg -q -F 'DEVELOPER_DIR: /Applications/Xcode_16.2.app/Contents/Developer' "$MACOS_14_WORKFLOW"
rg -q -F 'run: brew install actionlint cmake ripgrep' "$MACOS_14_WORKFLOW"
rg -q -F "run: swift --version | grep -q 'Swift version 6\\.'" "$MACOS_14_WORKFLOW"
rg -q -F 'run: ./scripts/run_ci_acceptance.sh' "$MACOS_14_WORKFLOW"
if rg -q 'setup-uv|uv sync|python install' "$MACOS_14_WORKFLOW"; then
    print -u2 "native acceptance workflow still installs Python"
    exit 1
fi

rg -q -F 'permissions:' "$RELEASE_WORKFLOW"
rg -q -F 'contents: write' "$RELEASE_WORKFLOW"
rg -q -F 'name: McSpeechface release' "$RELEASE_WORKFLOW"
rg -q -F 'name: Build and publish McSpeechface community DMG' "$RELEASE_WORKFLOW"
rg -q -F 'runs-on: macos-26' "$RELEASE_WORKFLOW"
rg -q -F 'DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer' "$RELEASE_WORKFLOW"
rg -q -F "printf 'import FoundationModels\\n' | swiftc -typecheck -" "$RELEASE_WORKFLOW"
rg -q -F 'run: brew install actionlint cmake ripgrep' "$RELEASE_WORKFLOW"
rg -q -F 'actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' "$RELEASE_WORKFLOW"
rg -q -F 'persist-credentials: false' "$RELEASE_WORKFLOW"
rg -q -F 'run: ./scripts/run_ci_acceptance.sh' "$RELEASE_WORKFLOW"
rg -q -F '"$ROOT/scripts/test_all.sh" 2>&1 | tee "$LOG"' \
    "$ROOT/scripts/run_ci_acceptance.sh"
rg -q -F '::error title=Acceptance suite failed::' \
    "$ROOT/scripts/run_ci_acceptance.sh"
rg -q -F 'gh release create "${create_args[@]}"' "$RELEASE_WORKFLOW"
rg -q -F -- '--verify-tag' "$RELEASE_WORKFLOW"
rg -q -F -- '--prerelease' "$RELEASE_WORKFLOW"
rg -q -F 'CFBundleShortVersionString' "$ROOT/scripts/release_metadata.sh"
rg -q -F 'release_metadata.sh "$GITHUB_REF_NAME" "$GITHUB_RUN_NUMBER"' "$RELEASE_WORKFLOW"
rg -q -F 'gh release upload "$GITHUB_REF_NAME"' "$RELEASE_WORKFLOW"
rg -q -F -- '--clobber' "$RELEASE_WORKFLOW"
rg -q -F 'gh release edit "$GITHUB_REF_NAME"' "$RELEASE_WORKFLOW"
rg -q -F 'dmg="dist/releases/McSpeechface-$VERSION-$BUILD_NUMBER-macOS-arm64.dmg"' \
    "$RELEASE_WORKFLOW"
rg -q -F 'published_dmg="dist/releases/McSpeechface-$ASSET_VERSION-$BUILD_NUMBER-macOS-arm64.dmg"' \
    "$RELEASE_WORKFLOW"
rg -q -F 'awk -v version="$ASSET_VERSION"' "$RELEASE_WORKFLOW"
rg -q -F -- '--notes-file "$notes"' "$RELEASE_WORKFLOW"
rg -q -F 'MCSPEECHFACE_RELEASE_BUILD_NUMBER' "$ROOT/scripts/test_all.sh"
rg -q -F 'MCSPEECHFACE_RELEASE_TAG' "$ROOT/scripts/test_all.sh"
rg -q -F 'MCSPEECHFACE_RELEASE_TAG: ${{ github.ref_name }}' "$RELEASE_WORKFLOW"
rg -q -F 'McSpeechfaceReleaseTag' "$ROOT/scripts/build_native_app.sh"

product_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/native/Info.plist")"
product_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/native/Info.plist")"
beta_metadata="$("$ROOT/scripts/release_metadata.sh" "v$product_version-beta.1" 77)"
print -r -- "$beta_metadata" | rg -q "^version=$product_version$"
print -r -- "$beta_metadata" | rg -q '^build_number=1$'
print -r -- "$beta_metadata" | rg -q "^asset_version=$product_version-beta.1$"
print -r -- "$beta_metadata" | rg -q "^release_name=McSpeechface $product_version beta 1$"
print -r -- "$beta_metadata" | rg -q '^prerelease=true$'
stable_metadata="$("$ROOT/scripts/release_metadata.sh" "v$product_version")"
print -r -- "$stable_metadata" | rg -q "^build_number=$product_build$"
print -r -- "$stable_metadata" | rg -q "^release_name=McSpeechface $product_version$"
print -r -- "$stable_metadata" | rg -q '^prerelease=false$'
if "$ROOT/scripts/release_metadata.sh" "$product_version" >/dev/null 2>&1; then
    print -u2 "release metadata accepted a tag without the v prefix"
    exit 1
fi
if "$ROOT/scripts/release_metadata.sh" "v$product_version" invalid >/dev/null 2>&1; then
    print -u2 "release metadata accepted an invalid build number"
    exit 1
fi
if "$ROOT/scripts/release_metadata.sh" v9.9.9 >/dev/null 2>&1; then
    print -u2 "release metadata accepted a tag that does not match Info.plist"
    exit 1
fi

if command -v actionlint >/dev/null; then
    actionlint "$MACOS_14_WORKFLOW" "$RELEASE_WORKFLOW"
else
    ruby -e 'require "yaml"; ARGV.each { |path| YAML.load_file(path) }' \
        "$MACOS_14_WORKFLOW" "$RELEASE_WORKFLOW"
fi

help="$($ROOT/scripts/build_native_app.sh --help)"
print -r -- "$help" | rg -q 'distribution'
print -r -- "$help" | rg -q 'dmg'
print -r -- "$help" | rg -q -- '--notary-profile'
print -r -- "$help" | rg -q -- '--build-number'
print -r -- "$help" | rg -q -- '--release-tag'
print -r -- "$help" | rg -q -- '--enable-sponsorship'
print -r -- "$help" | rg -q 'setup_local_signing.sh'

rg -q -F 'McSpeechface Local Development' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'extendedKeyUsage = codeSigning' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'security add-trusted-cert -r trustRoot -p codeSign' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'security delete-identity -Z "$fingerprint" -t "$KEYCHAIN"' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'codesign --verify --strict "$work/signing-test"' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'MCSPEECHFACE_LOCAL_SIGNING_IDENTITY' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'MCSPEECHFACE_LOCAL_SIGNING_KEYCHAIN' "$ROOT/scripts/build_native_app.sh"

missing_keychain_output="$(MCSPEECHFACE_LOCAL_SIGNING_KEYCHAIN="$ROOT/does-not-exist.keychain" \
    "$ROOT/scripts/build_native_app.sh" development 2>&1 || true)"
if [[ "$missing_keychain_output" != *"local signing keychain not found"* ]]; then
    print -u2 "development build accepted a missing local signing keychain"
    exit 1
fi

if "$ROOT/scripts/build_native_app.sh" development --version invalid >/dev/null 2>&1; then
    print -u2 "invalid release version was accepted"
    exit 1
fi

if "$ROOT/scripts/build_native_app.sh" distribution --skip-notarization >/dev/null 2>&1; then
    print -u2 "distribution build accepted a missing signing identity"
    exit 1
fi

for credential_option in \
    "--signing-identity Developer" \
    "--notary-profile profile" \
    "--skip-notarization"; do
    if "$ROOT/scripts/build_native_app.sh" dmg ${(z)credential_option} >/dev/null 2>&1; then
        print -u2 "dmg build accepted a distribution credential option"
        exit 1
    fi
done

LOCK="$ROOT/.build/native-build.lock"
mkdir -p "$ROOT/.build"
if ! mkdir "$LOCK" 2>/dev/null; then
    print -u2 "cannot test native build locking while another build is active"
    exit 1
fi
print "$$" > "$LOCK/pid"
cleanup_lock_test() {
    [[ "$(cat "$LOCK/pid" 2>/dev/null || true)" == "$$" ]] || return
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup_lock_test EXIT INT TERM
if "$ROOT/scripts/build_native_app.sh" development >/dev/null 2>&1; then
    print -u2 "concurrent native build was not rejected"
    exit 1
fi
cleanup_lock_test
trap - EXIT INT TERM

LOGIN_MANAGER="$ROOT/Sources/McSpeechface/LoginItemManager.swift"
rg -q -F 'SMAppService.loginItem(identifier: loginItemBundleIdentifier)' "$LOGIN_MANAGER"
rg -q -F 'try service.register()' "$LOGIN_MANAGER"
rg -q -F 'try service.unregister()' "$LOGIN_MANAGER"
rg -q -F 'try previousMainAppService.unregister()' "$LOGIN_MANAGER"
rg -q 'legacyCleanupFailed' "$LOGIN_MANAGER"
rg -q -F 'propertyList["Label"] as? String == LegacyInstallationMigrator.previousBundleIdentifier' "$LOGIN_MANAGER"
rg -q -F 'arguments[0] == "/usr/bin/open"' "$LOGIN_MANAGER"
rg -q -F '== LegacyInstallationMigrator.previousApplicationName' "$LOGIN_MANAGER"

register_line="$(rg -n -F 'try enableService()' "$LOGIN_MANAGER" | head -1 | cut -d: -f1)"
cleanup_line="$(rg -n -F 'try removeLegacyLaunchAgent()' "$LOGIN_MANAGER" | head -1 | cut -d: -f1)"
[[ "$register_line" -lt "$cleanup_line" ]]

print "McSpeechface release engineering assertions passed"
