// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "BlazingFastTranscription",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "BlazingFastTranscription", targets: ["App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.1"),
        // FluidAudio ASR/VAD — vendored (Apache-2.0) under Vendor/FluidAudio. The app
        // relies on a local streaming-EOU API not present in any upstream release, so it
        // ships as a trimmed in-tree copy rather than an upstream package pin.
        .package(path: "Vendor/FluidAudio"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
    ],
    targets: [
        // C bridge target — exposes whisper.cpp headers to Swift.
        // The actual whisper/ggml implementation is pre-built as static libraries in lib/.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include"
        ),

        // C bridge target — exposes llama.cpp headers to Swift.
        // The actual llama/ggml implementation is pre-built as static libraries in lib/.
        // Depends on CWhisper for shared ggml headers.
        .target(
            name: "CLlama",
            dependencies: ["CWhisper"],
            path: "Sources/CLlama",
            publicHeadersPath: "include"
        ),

        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),

        .target(
            name: "AudioEngine",
            dependencies: ["ObjCExceptionCatcher"],
            path: "Sources/AudioEngine"
        ),

        .target(
            name: "Transcription",
            dependencies: ["CWhisper", "AudioEngine", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Transcription",
            resources: [.copy("Resources/dev-vocabulary-2026.txt")]
        ),

        .target(
            name: "Overlay",
            path: "Sources/Overlay"
        ),

        .target(
            name: "Clipboard",
            path: "Sources/Clipboard"
        ),

        .target(
            name: "HotkeyModule",
            dependencies: [
                .product(name: "HotKey", package: "HotKey"),
            ],
            path: "Sources/Hotkey"
        ),


        .executableTarget(
            name: "App",
            dependencies: [
                "AudioEngine",
                "Transcription",
                "Overlay",
                "Clipboard",
                "HotkeyModule",
                "CLlama",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios"),
            ],
            path: "Sources/App",
            exclude: ["AnalyticsSecrets.swift.example"],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/lib"]),
                .unsafeFlags(["-lwhisper", "-lllama", "-lllama-common",
                              "-lggml", "-lggml-base", "-lggml-cpu", "-lggml-metal", "-lggml-blas"]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreML"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedLibrary("c++"),
            ]
        ),

        .testTarget(
            name: "AudioEngineTests",
            dependencies: ["AudioEngine"],
            path: "Tests/AudioEngineTests"
        ),
        .testTarget(
            name: "TranscriptionTests",
            dependencies: ["Transcription"],
            path: "Tests/TranscriptionTests"
        ),
        .testTarget(
            name: "OverlayTests",
            dependencies: ["Overlay"],
            path: "Tests/OverlayTests"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["App"],
            path: "Tests/AppTests"
        ),
    ]
)
