# Speech model decision

Historical design notes from the initial prototype. See README.md for current
Saywick features, defaults, history retention, and model comparison behavior.

Last reviewed: 2026-09-04

## Decision

Use **Moonshine v2 Medium Streaming** as the default experimental engine and **Apple SpeechAnalyzer** as the device baseline. Keep capture orchestration, transcript state, post-processing, and keyboard transport outside both adapters.

Moonshine is the best starting point for this particular product because it is designed for incremental streaming, has a current native Swift package, emits partial and completed lines, reports phrase-final latency directly, runs on device, and is MIT-licensed along with its current English streaming models. Version 0.1.5 is pinned in `project.yml` so upstream API changes cannot silently break the app.

Apple SpeechAnalyzer is important even though it is not an open-weight model. It is on-device, system-managed, specifically designed for live and long-form transcription, and costs almost no app bundle or model-maintenance overhead. It provides a strong “should we ship another model at all?” baseline on the exact phone.

## Candidate comparison

| Engine | Streaming behavior | iPhone integration | Why it is or is not first |
|---|---|---|---|
| Moonshine v2 Medium Streaming | Native incremental streaming with finalized lines and phrase latency | Current Swift package and iOS binary framework | Default: best combination of product-shaped streaming API, local execution, instrumentation, and replaceability |
| Apple SpeechAnalyzer | Native progressive live transcription | First-party iOS 26 framework and system model assets | Baseline: lowest integration and maintenance burden, but not open weight and less model-level control |
| FluidAudio Parakeet EOU 120M | True streaming with 160/320/1280 ms variants | Core ML and iOS compatible | Strong next adapter. Current published streaming benchmarks are primarily on Apple M2 rather than this iPhone, so measure it locally before replacing Moonshine |
| FluidAudio Nemotron Speech Streaming 0.6B | True RNNT streaming with several latency tiers | Core ML; documentation includes iOS execution advice | Interesting accuracy candidate, but much larger and needs direct thermal/memory testing on iPhone 16 Pro |
| WhisperKit / whisper.cpp | Mature Whisper inference; live UX is typically chunked/sliding-window | Both have proven Apple-platform support | Excellent fallback for multilingual coverage and ecosystem maturity, but less naturally streaming than the selected model family |

This is a provisional engineering choice, not a universal leaderboard claim. Public WER results use different data, normalization, hardware, quantization, and latency definitions. The project therefore measures candidates on one captured corpus and the target phone before promoting a new default.

## Product lessons applied

- **Superwhisper:** separate transcription from context/style cleanup; expose modes without forcing a cloud account; make offline state legible.
- **Spokenly:** pair a containing app with an iOS keyboard; support a start trigger outside the keyboard; let the keyboard finish and insert; expose local model choice.
- **Wispr Flow:** keep the keyboard’s primary action and state obvious; provide undo/dictionary/style affordances later; explicitly handle the case where the containing app has been suspended.

The first implementation intentionally does not retain history or inspect surrounding text. Those features add privacy surface area and are not required to validate recognition quality and latency.

## Swapping an engine

Add a case to `SpeechEngineID`, implement `LiveSpeechEngine`, and add it to `LiveSpeechEngineFactory`. The adapter owns any model-specific capture or stream mechanics and emits only four shared updates: preparing, partial, final, and failure. The app state machine, metrics, cleanup stage, App Group bridge, and keyboard require no changes.

The next adapter should use a shared PCM source so a prerecorded fixture can feed every engine byte-for-byte. Live adapters currently own their microphone path because that lets the first device build validate both vendor SDKs quickly.

## Primary sources

- [Moonshine Voice repository and license](https://github.com/moonshine-ai/moonshine)
- [Moonshine Swift package](https://github.com/moonshine-ai/moonshine-swift)
- [Moonshine v0.1.5 release](https://github.com/moonshine-ai/moonshine-swift/releases/tag/v0.1.5)
- [Apple SpeechAnalyzer documentation](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple’s SpeechAnalyzer sample](https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app)
- [Apple Foundation Models overview](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [FluidAudio models](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)
- [FluidAudio benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- [WhisperKit](https://github.com/argmaxinc/whisperkit)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
- [Superwhisper for iOS](https://superwhisper.com/ios)
- [Spokenly background dictation](https://spokenly.app/docs/ios/background-dictation)
- [Wispr Flow iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- [Apple iOS capability matrix](https://developer.apple.com/help/account/reference/supported-capabilities-ios)
- [Apple membership comparison](https://developer.apple.com/support/compare-memberships/)
