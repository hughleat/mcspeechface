#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/swift_compatibility.zsh"
mkdir -p "$ROOT/.build/ModuleCache"

swiftc \
    "${MCSPEECHFACE_SWIFTC_COMPATIBILITY_ARGS[@]}" \
    -module-cache-path "$ROOT/.build/ModuleCache" \
    "$ROOT/Sources/McSpeechface/ModifierEventState.swift" \
    "$ROOT/tests/McSpeechfaceTests/ModifierEventStateTests.swift" \
    -o "$ROOT/.build/modifier-event-state-tests"

"$ROOT/.build/modifier-event-state-tests"
