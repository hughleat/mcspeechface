# Developing McSpeechface

McSpeechface is a native Swift package with no Python runtime or MLX dependency.

## Prerequisites

- An Apple Silicon Mac running macOS 14 or later.
- Xcode 16 or compatible Command Line Tools with Swift 6.
- CMake and ripgrep. The complete CI-equivalent check also uses actionlint.
- At least 8 GB of free disk space for Swift dependencies, the optional local
  correction runtime, and temporary release artifacts.

Homebrew can install the external build tools with
`brew install cmake ripgrep actionlint`.

## Build

For a quick compile and unit-test pass:

```sh
./scripts/test_swift.sh
```

Create a locally signed app with:

```sh
./scripts/setup_local_signing.sh
./scripts/build_native_app.sh development
open "dist/McSpeechface.app"
```

The native app is built at `dist/McSpeechface.app`. The signing setup is needed
only once and keeps macOS permissions stable across local rebuilds.

The reviewed Finder layout used by community DMGs can be regenerated with
`./scripts/create_dmg_template.sh` after changing its background or contents.
The script downloads two pinned, build-only Python packages into a temporary
directory; neither Python nor those packages are included in McSpeechface. A
regenerated image receives fresh filesystem metadata, so visually review it and
update the checksum pinned in `build_native_app.sh` before committing it.

## Complete Check

```sh
./scripts/test_all.sh
```

The complete check runs Swift tests, focused native assertions, a production
Core ML transcription, and mounted DMG verification. It can download model
assets and create a multi-gigabyte `.build` directory, so allow adequate free
disk space. CI runs the same acceptance path on macOS 14.

## Package

Create the free GitHub release artifact with:

```sh
./scripts/build_native_app.sh dmg
```

Models are downloaded by the app and are not part of the app or DMG. See the
[release guide](RELEASING.md) for signed and notarized builds and the complete
publishing process.

Pushing a beta tag such as `vX.Y.Z-beta.N` runs the complete acceptance suite
and publishes the verified community DMG and SHA-256 checksum as a GitHub
Latest release labelled as a public beta. This keeps the installer visible on
the repository page. Stable `vX.Y.Z` tags publish a normal release without the
beta label.
