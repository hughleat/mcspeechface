// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "McSpeechface",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "McSpeechface", targets: ["McSpeechface"]),
        .executable(name: "McSpeechfaceCommand", targets: ["McSpeechfaceCLI"]),
        .library(name: "McSpeechfaceEditing", targets: ["McSpeechfaceEditing"]),
        .library(name: "McSpeechfaceIPC", targets: ["McSpeechfaceIPC"]),
        .library(name: "McSpeechfaceRecognition", targets: ["McSpeechfaceRecognition"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.1.0"
        ),
    ],
    targets: [
        .target(
            name: "McSpeechfaceEditing",
            path: "Sources/McSpeechfaceEditing"
        ),
        .target(
            name: "McSpeechfaceRecognition",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/McSpeechfaceRecognition"
        ),
        .executableTarget(
            name: "McSpeechface",
            dependencies: ["McSpeechfaceEditing", "McSpeechfaceIPC", "McSpeechfaceRecognition"],
            path: "Sources/McSpeechface"
        ),
        .target(
            name: "McSpeechfaceIPC",
            path: "Sources/McSpeechfaceIPC"
        ),
        .executableTarget(
            name: "McSpeechfaceCLI",
            dependencies: ["McSpeechfaceIPC"],
            path: "Sources/McSpeechfaceCLI"
        ),
        .testTarget(
            name: "McSpeechfaceTests",
            dependencies: ["McSpeechface", "McSpeechfaceEditing", "McSpeechfaceRecognition"],
            path: "tests/McSpeechfaceTests",
            exclude: [
                "ModifierEventStateTests.swift",
                "SnippetEditStateTests.swift",
                "SupportPromptPolicyAssertions.swift",
            ],
            sources: [
                "BuildFeaturesTests.swift",
                "CommandTranscriptCompletionTests.swift",
                "DiagnosticsReportTests.swift",
                "CommandLineToolInstallerTests.swift",
                "DictationModelCatalogTests.swift",
                "ErrorRecoveryTests.swift",
                "FileTranscriptionOperationOwnerTests.swift",
                "ModelComparisonViewTests.swift",
                "ModelDownloadStateTests.swift",
                "ModelManagementViewTests.swift",
                "LegacyInstallationMigratorTests.swift",
                "NativeTextFinalizerTests.swift",
                "NativeMcSpeechfaceStoreTests.swift",
                "SetupReadinessTests.swift",
                "SettingsConstructionTests.swift",
                "SettingsDeepLinkTests.swift",
                "SupportPromptPolicyTests.swift",
                "TranscriptReviewTests.swift",
                "TranscriptionJobGateTests.swift",
                "TranscriptExportTests.swift",
                "UpdateCheckerTests.swift",
            ]
        ),
        .testTarget(
            name: "McSpeechfaceEditingTests",
            dependencies: ["McSpeechfaceEditing"],
            path: "tests/McSpeechfaceEditingTests"
        ),
        .testTarget(
            name: "McSpeechfaceRecognitionTests",
            dependencies: [
                "McSpeechfaceRecognition",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "tests/McSpeechfaceRecognitionTests"
        ),
        .testTarget(
            name: "McSpeechfaceIPCTests",
            dependencies: ["McSpeechfaceIPC", "McSpeechfaceCLI"],
            path: "tests/McSpeechfaceIPCTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
