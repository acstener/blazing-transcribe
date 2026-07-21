# Building Blazing Transcribe

macOS 15+, Xcode / Swift 5.9 toolchain, Apple Silicon.

The app links pre-built native static libraries (whisper.cpp, llama.cpp, ggml,
and a Rust text-processing lib) from `lib/`, which is **not** checked in. You
build those locally first, then `swift build`.

## 1. Native libraries → `lib/`

```bash
Scripts/build-whisper.sh     # builds libwhisper + ggml static libs
Scripts/build-llama.sh       # builds libllama + llama-common
Scripts/build-metallib.sh    # compiles the Metal shaders
Scripts/download-model.sh    # fetches the ASR/LLM model weights
```

These produce every static library `Package.swift` links (`libwhisper`,
`libllama`, `libllama-common`, and the `ggml` libs). Copy the resulting `.a`
files into `lib/`.

## 2. FluidAudio dependency

Speech-to-text runs NVIDIA Parakeet TDT on the Apple Neural Engine via
[FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0). A
trimmed, ASR-only copy is **vendored in-tree** under `Vendor/FluidAudio` and
`Package.swift` references it by local path — no action needed.

> It's vendored (rather than pinned to an upstream tag) because the app relies
> on a streaming end-of-utterance API not present in any upstream release. Only
> the ASR/VAD library is included; the TTS target and its ~85MB ESpeakNG
> framework are omitted. See `Vendor/FluidAudio/LICENSE` for attribution.

## 3. Analytics config (required to compile)

Analytics keys are kept out of source control, so you must create the config
file before building — copy the template:

```bash
cp Sources/App/AnalyticsSecrets.swift.example Sources/App/AnalyticsSecrets.swift
```

Leave the key empty and the app runs fully but **sends no telemetry** (the
default for source/fork builds). The official distributed build fills in a real
PostHog key here; `AnalyticsSecrets.swift` is gitignored so that key is never
committed.

## 4. Build & run

```bash
swift build -c release
swift run BlazingFastTranscription
```

The app needs **Microphone** and **Accessibility** permissions (the latter for
CGEvent keyboard injection). Grant both in System Settings → Privacy & Security.
