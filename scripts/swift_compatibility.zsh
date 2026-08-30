#!/bin/zsh

typeset -ga MCSPEECHFACE_SWIFT_COMPATIBILITY_ARGS=()
typeset -ga MCSPEECHFACE_SWIFTC_COMPATIBILITY_ARGS=()

sdk_root="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
sdk_interface="$sdk_root/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
compiler_version="$(swiftc --version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1)"
sdk_compiler_version="$(sed -nE 's|// swift-compiler-version: Apple Swift version ([0-9]+\.[0-9]+\.[0-9]+).*|\1|p' "$sdk_interface" 2>/dev/null | head -1)"

if [[ -n "$compiler_version" && -n "$sdk_compiler_version" \
    && "$compiler_version" != "$sdk_compiler_version" \
    && "${compiler_version%.*}" == "${sdk_compiler_version%.*}" ]]; then
    MCSPEECHFACE_SWIFT_COMPATIBILITY_ARGS=(
        -Xswiftc -interface-compiler-version
        -Xswiftc "$sdk_compiler_version"
    )
    MCSPEECHFACE_SWIFTC_COMPATIBILITY_ARGS=(
        -interface-compiler-version "$sdk_compiler_version"
    )
fi
