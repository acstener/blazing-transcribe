# Blazing Transcribe

Local, always-on speech-to-text for macOS. Speak into your mic and text
auto-types into whatever app is focused — no keyboard shortcut required, no
cloud, no subscription. Everything runs on-device.

**~530ms** from speech-end to text-on-screen for short utterances.

## How it works

```
Mic → Ring Buffer → Silero VAD → Parakeet TDT (ANE) → Keyboard injection
      16kHz mono    ML endpoint   ~90ms on-device      CGEvent
```

1. Microphone captures at 16kHz into an in-memory ring buffer.
2. Silero VAD (ML) detects speech start/stop with an adaptive silence timeout.
3. NVIDIA Parakeet TDT runs speech-to-text entirely on the Apple Neural Engine
   via [FluidAudio](https://github.com/FluidInference/FluidAudio).
4. Text is injected into the focused app via macOS `CGEvent` keyboard events.

**Your audio never leaves your Mac.** No step in the transcription pipeline makes
a network call — it's 100% on-device. Live capture stays in an in-memory ring
buffer; longer recordings briefly use a local temp file (deleted right after
transcribing), and any saved transcription history lives only on your Mac.
Nothing is ever uploaded.

## Features

- **Always-on mode** — VAD auto-detects speech and types it; no hotkey needed.
- **Push-to-talk & toggle** — hold `fn` to dictate, double-tap to switch modes.
- **On-device cleanup** — optional local LLM (or regex) fixes punctuation and
  filler. Cloud providers are bring-your-own-key; nothing is embedded.
- **Sub-600ms latency** on Apple Silicon.

## Building

See [BUILDING.md](BUILDING.md). Requires macOS 15+, Apple Silicon, and a local
build of the native libraries.

## Architecture

| Module | Responsibility |
|---|---|
| `AudioEngine` | Mic capture, ring buffer, VAD |
| `Transcription` | ASR engine (FluidAudio Parakeet), model management |
| `Overlay` | Status HUD |
| `Clipboard` | Local `NSPasteboard` paste path |
| `HotkeyModule` | Global shortcut / `fn` monitoring |
| `App` | Orchestration, UI, text delivery |

## License

See [LICENSE](LICENSE).
