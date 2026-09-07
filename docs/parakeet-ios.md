# Experimental Parakeet engine

The optional engine uses the same Q8_0 Parakeet Unified English 0.6B weights
as the measured Handy setup, with transcribe.cpp 0.2.0 revision
`93151602c670f0dbf6703b1d87a8822f87581a0b`. Existing engine preferences are unchanged.

The runtime and Swift wrapper come from the same pinned source revision. The
upstream Swift distribution repository was unavailable during integration, so
`make parakeet-bootstrap` builds the framework locally (Xcode and CMake required).
Run it before `make project` on a fresh checkout. Generated dependencies live
under ignored `.build/Parakeet`; no native binaries or model weights enter git.
Only the containing application links the runtime, not the keyboard extension.

The bootstrap disables Metal on device as well as simulator. The upstream
runtime initializes registered GPU backends even for an explicit CPU request;
the first Metal-enabled device test exited during backend initialization.
An initial CPU-only test also exited, then a repeated CPU run loaded and
transcribed successfully; those early exits are not a confirmed Metal defect.
CPU also avoids depending on GPU execution while the app is in the background.
The engine uses four CPU threads and default native streaming options.
The iOS 26 build enables ARMv8.2 dot-product instructions on arm64 (supported
by the A13 and newer phones targeted by this application), while simulator x86
retains its own architecture settings.
The Apple Accelerate build also enables ggml's BLAS backend and requests
`cpuAccel`. The packaging patch removes upstream's forced `GGML_BLAS=OFF` while
preserving that default for builds that do not explicitly enable it.

Model download is pinned to Hugging Face revision
`7e948f21b7bdbac698d3318db9d350f1096f3b6c`, exactly 731,357,568 bytes, with SHA-256
`4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795`.
Downloads go through a temporary file, are verified before use, and are excluded
from backups. Model and runtime attribution ship in `Parakeet-Licenses.txt`.

Audio is resampled to mono float32 16 kHz, then fed to one native stream until
Stop. Pauses do not finalize or reset it. Whole native hypotheses replace the
partial transcript; Stop publishes one final transcript. There is no casing or
punctuation rewrite. Existing optional cleanup still runs after Stop: select
Raw transcript when comparing engines. Spoken commands are intentionally
unavailable in this experimental mode because it has no pause-triggered finals.

Unlike Handy, live capture currently forwards silence instead of applying
Silero VAD. Compare on the same already-filtered recording to isolate runtime,
backend and model behavior; raw microphone comparisons also measure that VAD
difference. File comparison uses the same native worker as microphone capture.

## Opt-in phone benchmark

`ParakeetDeviceTests` skips unless `Documents/ParakeetBench/manifest.json` exists
in the app data container. Ordinary unit tests do not download models or record
audio. Each fixture contains `wav`, Handy's raw `handy` text, and a `paced` flag.
Audio must be mono 16 kHz. Use `Tools/Parakeet/bench.py stage --help` to assemble
a private fixture directory from existing Handy harness results. Use `--paced`
for sustained realtime playback, including recordings longer than five minutes.

Copy that directory with `xcrun devicectl device copy to`, using domain type
`appDataContainer`, domain identifier `com.yourname.localvoicekeyboard.app`, and
destination `Documents/ParakeetBench`. Optionally stage the verified model under
`Library/Application Support/Parakeet` to reuse local weights without a download.

Run `xcodebuild test -only-testing:SaywickAppTests/ParakeetDeviceTests` with the
project's device signing options. The test intentionally launches the app but
never starts its microphone. Copy `Documents/ParakeetBench/results.json` back and
run `python3 Tools/Parakeet/bench.py report RESULTS --output REPORT.md`.
After success the test removes only its opt-in manifest, so ordinary later test
runs skip this benchmark. Never use `devicectl copy --remove-existing-content`
for cleanup: during this experiment that operation unexpectedly reset the app's
data domain despite a benchmark-subdirectory destination. Keep transfer cleanup
disabled and remove only specific test files from within the app.

Results include raw text, Handy comparison text, audio and compute time, Stop
latency, peak physical footprint, thermal state and battery snapshots. Outputs
are private and ignored. Word disagreement is not WER against human truth.
The test does not establish background microphone behavior or battery endurance;
those require separate sustained real-use testing.

## Initial device results (2026-09-06)

On iPhone 16 Pro / iOS 26.6.1, the generic CPU build loaded the model at roughly
1.1–1.2 GB process footprint and transcribed four short fixtures with identical
words to the existing Handy results. Three matched capitalization and punctuation
exactly. The five-second thinking-pause fixture capitalized “The Blue Notebook”
where Handy did not; Handy's baseline applies Silero and this run forwards silence,
so that difference cannot be attributed solely to the iPhone backend.

The generic CPU attempt on the 312.36-second natural recording was interrupted
after the overall test exceeded 623 seconds without completing it. Thermal samples
remained nominal. This is a failed realtime-performance baseline, not a complete
long-recording accuracy result. A separate ARM dot-product optimized run is required
before assessing the candidate build's sustained performance.

The completed ARM dot-product CPU run reproduced Handy's full natural transcript
exactly: all 465 words, capitalization and punctuation, including 19 terminal
punctuation marks. It took 412.85 seconds for 312.36 seconds of audio, with
99.27 seconds maximum input backlog and 1.51 seconds to finalize. Sampled peak
footprint for that fixture was 1,184 MB and thermal state remained nominal.
This establishes output parity for this recording, but fails realtime throughput.
Battery stayed at 80% while charging state changed during the run; it is not a
battery-endurance measurement. Private results: `.build/Parakeet/dotprod-results.json`.

## Final Accelerate result

The same phone, weights, four-thread setting and recordings were tested with
Apple Accelerate enabled. All five fixtures completed. The 312.36-second natural
recording again matched Handy exactly, including all 465 words, capitalization
and punctuation, without any cleanup.

| Measurement | Dot-product CPU | CPU + Accelerate |
|---|---:|---:|
| Audio duration | 312.36 s | 312.36 s |
| Realtime-paced elapsed time | 412.85 s | 312.65 s |
| Time inside feed calls | 399.75 s | 95.05 s |
| Maximum input backlog | 99.27 s | 0.50 s |
| Stop finalization | 1.51 s | 0.28 s |
| Sampled peak process footprint | 1,184 MB | 1,214 MB |
| Start/end thermal state | Nominal / nominal | Nominal / nominal |
| Full raw text matches Handy | Yes | Yes |

Accelerate supplies adequate throughput for this sustained replay. Input backlog
does not include the model's inherent lookahead or measure keyboard insertion
latency. The phone was charging (80% to 85%); no battery-life claim is supported.
This was a file replay, not a background microphone/keyboard session. Those
conditions and a broader audio corpus still need real-use validation.

All short fixtures matched Handy's words; the five-second synthetic thinking pause
still capitalized “The Blue Notebook” differently. The live engine does not yet
apply Handy's Silero filter, so this is not a guarantee against every pause-related
capitalization difference.

The integration does not change the selected engine programmatically. However,
the post-test cleanup incident described above reset the installed app's local
preferences and history. A cached-preferences recovery check found only the
default MAI-Transcribe-2 / Foundation Models settings, with no saved endpoint or
custom words. The model was restored; no recoverable history copy was found in
the workspace. This operational failure is separate from the successful model
and performance measurements.

Validation: device and simulator builds passed; 44 core tests, nine Python
benchmark tests, five device audio buffer/archive tests, and the final native
benchmark passed. Private artifacts: `.build/Parakeet/accelerate-results.json`,
`.build/Parakeet/accelerate-report.md`, and
`.build/Parakeet/device-accelerate-benchmark.xcresult`.
