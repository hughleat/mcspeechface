#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
dmg_args=()
if [[ -n "${MCSPEECHFACE_RELEASE_VERSION:-}" || -n "${MCSPEECHFACE_RELEASE_BUILD_NUMBER:-}" || -n "${MCSPEECHFACE_RELEASE_TAG:-}" ]]; then
    [[ -n "${MCSPEECHFACE_RELEASE_VERSION:-}" && -n "${MCSPEECHFACE_RELEASE_BUILD_NUMBER:-}" && -n "${MCSPEECHFACE_RELEASE_TAG:-}" ]] || {
        print -u2 "MCSPEECHFACE_RELEASE_VERSION, MCSPEECHFACE_RELEASE_BUILD_NUMBER, and MCSPEECHFACE_RELEASE_TAG must be set together"
        exit 1
    }
    dmg_args=(
        --version "$MCSPEECHFACE_RELEASE_VERSION"
        --build-number "$MCSPEECHFACE_RELEASE_BUILD_NUMBER"
        --release-tag "$MCSPEECHFACE_RELEASE_TAG"
    )
fi

cd "$ROOT"
"$ROOT/scripts/test_swift.sh"
"$ROOT/scripts/test_app_paths_migration.sh"
"$ROOT/scripts/test_hotkey_state.sh"
"$ROOT/scripts/test_snippet_edit_state.sh"
"$ROOT/scripts/test_support_prompt_policy.sh"
"$ROOT/scripts/test_private_file_permissions.sh"
"$ROOT/scripts/test_release_engineering.sh"
"$ROOT/scripts/test_coreml_production.sh"
"$ROOT/scripts/test_sponsorship_builds.sh"
"$ROOT/scripts/build_native_app.sh" development
"$ROOT/scripts/build_native_app.sh" dmg "${dmg_args[@]}"

print "All McSpeechface checks passed"
