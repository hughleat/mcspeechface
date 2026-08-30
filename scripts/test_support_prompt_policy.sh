#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/swift_compatibility.zsh"
SDKS=(/Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk(N/))
SDK="${SDKS[1]:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$ROOT/.build/ModuleCache"

compile_and_run() {
    local state="$1"
    shift
    local executable="$ROOT/.build/support-prompt-policy-tests-$state"

    SDKROOT="$SDK" swiftc \
        "${MCSPEECHFACE_SWIFTC_COMPATIBILITY_ARGS[@]}" \
        -module-cache-path "$ROOT/.build/ModuleCache" \
        "$@" \
        "$ROOT/Sources/McSpeechface/BuildFeatures.swift" \
        "$ROOT/Sources/McSpeechface/SupportPromptPolicy.swift" \
        "$ROOT/tests/McSpeechfaceTests/SupportPromptPolicyAssertions.swift" \
        -o "$executable"
    "$executable" "$state"
}

compile_and_run disabled
compile_and_run enabled -D MCSPEECHFACE_SPONSORSHIP_ENABLED
