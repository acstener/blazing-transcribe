// swift-tools-version: 6.0
import PackageDescription

// Vendored, trimmed copy of FluidAudio (Apache-2.0, github.com/FluidInference/FluidAudio),
// pinned to the v0.7.8 API plus the local streaming-EOU additions this app relies on.
// TTS (FluidAudioTTS + ESpeakNG.xcframework), the CLI, and tests are intentionally
// omitted — this app only uses the ASR/VAD library. See LICENSE for attribution.
let package = Package(
    name: "FluidAudio",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "FluidAudio",
            targets: ["FluidAudio"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6")
    ],
    targets: [
        .target(
            name: "FluidAudio",
            dependencies: [
                "FastClusterWrapper",
                "MachTaskSelfWrapper",
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/FluidAudio"
        ),
        .target(
            name: "FastClusterWrapper",
            path: "Sources/FastClusterWrapper",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MachTaskSelfWrapper",
            path: "Sources/MachTaskSelfWrapper",
            publicHeadersPath: "include"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
