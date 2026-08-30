#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/swift_compatibility.zsh"
mkdir -p "$ROOT/.build/ModuleCache"

swiftc \
    "${MCSPEECHFACE_SWIFTC_COMPATIBILITY_ARGS[@]}" \
    -module-cache-path "$ROOT/.build/ModuleCache" \
    "$ROOT/Sources/McSpeechface/SnippetEditState.swift" \
    "$ROOT/tests/McSpeechfaceTests/SnippetEditStateTests.swift" \
    -o "$ROOT/.build/snippet-edit-state-tests"

"$ROOT/.build/snippet-edit-state-tests"
