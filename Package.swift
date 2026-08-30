// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Tiro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tiro", targets: ["Tiro"]),
        .executable(name: "TiroCommand", targets: ["TiroCLI"]),
        .library(name: "TiroEditing", targets: ["TiroEditing"]),
        .library(name: "TiroIPC", targets: ["TiroIPC"]),
        .library(name: "TiroRecognition", targets: ["TiroRecognition"]),
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
            name: "TiroEditing",
            path: "Sources/TiroEditing"
        ),
        .target(
            name: "TiroRecognition",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/TiroRecognition"
        ),
        .executableTarget(
            name: "Tiro",
            dependencies: ["TiroEditing", "TiroIPC", "TiroRecognition"],
            path: "Sources/Tiro"
        ),
        .target(
            name: "TiroIPC",
            path: "Sources/TiroIPC"
        ),
        .executableTarget(
            name: "TiroCLI",
            dependencies: ["TiroIPC"],
            path: "Sources/TiroCLI"
        ),
        .testTarget(
            name: "TiroTests",
            dependencies: ["Tiro", "TiroEditing", "TiroRecognition"],
            path: "tests/TiroTests",
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
                "NativeTextFinalizerTests.swift",
                "NativeTiroStoreTests.swift",
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
            name: "TiroEditingTests",
            dependencies: ["TiroEditing"],
            path: "tests/TiroEditingTests"
        ),
        .testTarget(
            name: "TiroRecognitionTests",
            dependencies: [
                "TiroRecognition",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "tests/TiroRecognitionTests"
        ),
        .testTarget(
            name: "TiroIPCTests",
            dependencies: ["TiroIPC", "TiroCLI"],
            path: "tests/TiroIPCTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
