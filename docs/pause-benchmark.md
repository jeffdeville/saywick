# Raw transcription pause benchmark

The app now requests 1,500 ms of silence before Microsoft server VAD ends a turn
(previously 500 ms). Live Azure testing on the starter corpus showed a modest reduction in false
sentence breaks; natural human dictation still needs broader validation. A session must confirm the requested detector and duration.
Semantic detection stays a benchmark candidate until Azure testing establishes its
behavior with MAI Transcribe.

## What is compared

`Tools/PauseBench` feeds the same mono 16 kHz PCM16 audio to:

- `legacy500`: Saywick's former Microsoft configuration.
- `server1500`: the new app default.
- `server2000`: a longer thinking-pause allowance.
- `azureSemantic`: Azure semantic VAD, with a 1,500 ms silence parameter.
- `handy`: Handy's transcribe-cpp 0.2.0 streaming backend, using the selected GGUF
  model and the actual VAD source from a pinned Handy checkout.

The Azure runner imports `VoiceLiveProtocol` and `VoiceLiveTranscript` from the
app's core library. It replays audio at microphone speed, waits for session
confirmation, records service events, and uses the app's shared `VoiceLiveStopGate`: wait for commit acknowledgement and
transcription completion before sending Clear, then await its acknowledgement.
It bypasses text cleanup. The microphone capture/resampling layer and keyboard UI
are outside this desktop test.

The Handy runner reuses the pinned `SileroVad`, `SmoothedVad`, constants and frame
sizes directly. Its detector threshold is 0.3, with 450 ms pre-roll, 60 ms onset,
and 1,650 ms streaming hangover. It keeps one recognizer stream alive, uses default
RunOptions and StreamOptions, and returns authoritative `stream.text().full` after
finalize. It bypasses vocabulary replacement, filler removal, stutter collapse,
and LLM processing. This tests the pinned backend/audio path, **not UI automation
of the installed Handy binary**. Decoder work runs on the replay thread; under load
its timing can differ from Handy's separate capture/worker threads. The final short
VAD frame is zero-padded. `--handy-vad off` is an explicit audio-filter ablation,
not the normal Handy profile. Earshot is also supported.

The installed Handy model found during setup was Parakeet Unified English 0.6B
Q8_0. Its application settings had postprocessing and filler removal enabled;
pasted Handy output therefore is not necessarily raw recognizer output.

## Build

Requires macOS/Xcode Swift 6.2+, Rust, CMake and ffmpeg. Python uses only its
standard library. Dependencies download on the first Rust build. Model weights are
not automatically downloaded or committed.

```sh
mkdir -p .build
git clone https://github.com/cjpais/Handy.git .build/handy-source
git -C .build/handy-source checkout bc7facea3a777869182203cfcf5c90f7a98efd99
export HANDY_SOURCE="$PWD/.build/handy-source"
make pause-bench-build
make pause-bench-test
```

If CMake is not already installed, a project-local option is:

```sh
python3 -m venv .build/pause-bench-tools
.build/pause-bench-tools/bin/pip install cmake==4.4.3
export PATH="$PWD/.build/pause-bench-tools/bin:$PATH"
```

`HandyRunner/Cargo.lock` pins dependencies. Its build script verifies the Handy
commit and rejects modifications to the imported VAD source. The resulting binary
does not require the checkout at runtime.

## Generate and run

```sh
make pause-bench-fixtures

# Obtain these through your credential provider; do not put keys in command arguments.
# Required environment variable names: AZURE_SPEECH_ENDPOINT, AZURE_SPEECH_KEY.
# Endpoint is the same Azure resource root saved in Saywick.

python3 Tools/PauseBench/bench.py run .build/pause-bench/corpus/manifest.json \
  --output .build/pause-bench/comparison \
  --handy-model /absolute/path/to/parakeet-unified-en-0.6b-Q8_0.gguf \
  --silero-model /Applications/Handy.app/Contents/Resources/resources/models/silero_vad_v4.onnx \
  --repeats 3 --require-all --check-candidate server1500
```

For this project's `AzureSTT` item in the 1Password Private vault, use the wrapper
instead of setting environment variables manually:

```sh
python3 Tools/PauseBench/with_azure.py run .build/pause-bench/corpus/manifest.json \
  --output .build/pause-bench/azure-comparison \
  --profiles legacy500 server1500 server2000 azureSemantic --require-all
```

Approve the 1Password CLI prompt when requested. The wrapper reads the password/key
and endpoint URL directly into the benchmark process environment; it writes no
plaintext credentials file. Handy subprocesses do not receive the Azure variables.

Every requested Azure profile sends the fixture audio to the configured Azure
resource and may incur service charges. The default generated fixtures contain
only synthetic example speech. For a local-only baseline use `--profiles handy`.
For a short setup check add `--limit 1`. Missing credentials are recorded as skipped;
service rejection and runner failures are recorded as errors, never as empty
successful transcripts. `--require-all` makes incomplete runs fail. Results are
written incrementally, and old per-case output is removed before rerunning a case.

The report contains word error rate, false sentence breaks and false capitals at
annotated thinking pauses, missed genuine sentence breaks, unscorable boundaries,
raw text, and finalization delay after Stop. JSON files retain streaming events,
configuration, audio hashes, and model/backend provenance. `run.json` records the
manifest and working-diff hashes. Results and audio belong under ignored `.build`;
they may contain private speech when a real corpus is used.

`--check-candidate` requires matched successful legacy/candidate runs with identical
audio hashes and fails if aggregate word edits, false breaks, false capitals,
missed real breaks, or unscorable boundaries increase. It is a non-regression gate,
not proof of improvement; inspect per-case failures and latency before promoting a
profile. Run multiple repetitions because a remote model may vary between runs.

## Corpus and interpretation

The starter corpus has two mid-sentence scenarios and one genuine sentence break,
each with 0, 500, 1,000, 2,000 and 5,000 ms inserted silence. The spoken samples stay
identical across gap variants. There are 20 ms speech-edge margins, so the inserted
silence duration is not a claim about the detector's exact measured silence.

Starter speech is synthesized as separate left/right fragments. It is useful for
plumbing and controlled comparisons, but fragment prosody can itself sound like a
sentence break. **Do not select a production winner from this synthetic corpus
alone.** Add natural full-utterance recordings, quiet and noisy speech, names,
repetitions, fillers and pauses longer than five seconds. Include no-pause controls
and actual sentence endings. Handy is a peer comparator; the human reference is
ground truth.

Custom corpus format (`before_word` is a zero-based index into reference words;
words include internal apostrophes):

```json
{
  "version": 1,
  "cases": [{
    "id": "natural-thinking-2s",
    "wav": "natural-thinking-2s.wav",
    "reference": "Please send the report tomorrow.",
    "source": "human-recorded",
    "pauses": [{"before_word": 4, "kind": "thinking", "inserted_ms": 2000}]
  }]
}
```

Use `kind: "sentence"` for a genuine sentence boundary. Exact word alignment is
required on both sides of a pause; dropped/inserted anchors are marked unscorable
and still count toward word errors. Proper nouns and the pronoun I are not counted
as false capitals. Punctuation scoring is focused on the annotated boundary, not
a general grammar evaluator. Convert other audio formats once using ffmpeg to
16 kHz mono PCM16 WAV, then give that same file to both runners.

## Source references

- [Pinned Handy stream worker](https://github.com/cjpais/Handy/blob/bc7facea3a777869182203cfcf5c90f7a98efd99/src-tauri/src/managers/transcription.rs#L961)
- [Pinned Handy VAD](https://github.com/cjpais/Handy/blob/bc7facea3a777869182203cfcf5c90f7a98efd99/src-tauri/src/audio_toolkit/vad/mod.rs)
- [Microsoft Voice Live turn detection](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/voice-live-how-to#turn-detection-parameters)

Azure documents `azure_semantic_vad` for all model types; the different
`semantic_vad` type and its `eagerness` option are not compatible with this app's
text-model session. Actual compatibility is still checked by the replay runner.

## First local baseline (2026-09-06)

The 15 generated Samantha fixtures completed successfully with the installed
Parakeet Unified Q8_0 model through the pinned Handy backend. Word error rate was
0%; four of ten thinking-pause cases had both a false terminal period and a false
capital. All five true sentence boundaries were preserved. The report-fragment
scenario broke at every nonzero inserted pause; the incomplete “pick up … the blue
notebook” scenario stayed joined even at five seconds. This is consistent with
content/prosody mattering alongside silence duration, but does not establish the
cause or represent natural human dictation quality.

All four Azure profiles were explicitly skipped because desktop Azure credentials
were unavailable. No measured improvement or winning Microsoft profile has been
established. Detailed initial output is at `.build/pause-bench/initial/report.md`.


## Repeated pause and Stop-edge checks

The challenge subcommand reproduces the follow-up corpus used in live testing:
two difficult thinking pauses, a genuine sentence boundary, immediate Stop after
the final word, and Stop after five additional seconds of silence.

```sh
python3 Tools/PauseBench/bench.py challenge .build/pause-bench/corpus/manifest.json \
  --output .build/pause-bench/challenge-corpus
python3 Tools/PauseBench/with_azure.py run .build/pause-bench/challenge-corpus/manifest.json \
  --output .build/pause-bench/azure-challenge \
  --profiles legacy500 server1500 --repeats 2 --require-all --check-candidate server1500
```

For multiple iterations under one 1Password authorization, launch
`python3 Tools/PauseBench/with_azure.py --session`. Once ready, submit JSON arrays
of `bench.py run` arguments, one per line. Enter `exit` when finished to release
the process and its in-memory credentials. This session only invokes the benchmark;
it does not accept shell commands.

## Live Azure results (2026-09-06)

Using AzureSTT from 1Password, all 60 primary Azure runs completed (15 fixtures ×
four profiles). The local Handy baseline uses identical input audio hashes for
all 15 cases. All systems had zero word errors and preserved all five genuine
sentence boundaries. Thinking-pause scores were:

| Profile | False breaks / 10 | Unexpected capitals across all aligned words |
|---|---:|---:|
| Handy Parakeet raw | 4 | 4 |
| MAI server VAD 500 ms | 4 | 8 |
| MAI server VAD 1,500 ms | 3 | 5 |
| MAI server VAD 2,000 ms | 3 | 5 |
| MAI Azure semantic VAD | 3 | 5 |

The two-second pause after “Please remind me to pick up” split and title-cased
“The Blue Notebook” at 500 ms, but stayed joined and normally cased at 1,500 ms.
Two additional repetitions reproduced that distinction. Five-second pauses still
caused false boundaries in both settings. MAI also inserted a false period inside
a single completed recognition item, confirming that concatenating service turns
is not the entire cause. Keep 1,500 ms: neither 2,000 ms nor semantic detection
improved this corpus. These are controlled synthetic fixtures, not a claim about
general human dictation accuracy.

Median post-Stop finalization was approximately 0.86–0.88 seconds for the Azure
profiles; Handy's was 0.09 seconds. This measures finalization on this Mac/network,
not iPhone responsiveness, and does not include model loading.

The first live checks uncovered two Stop-path issues, now fixed in both the app
and replay runner through `VoiceLiveStopGate`:

1. Clear can be acknowledged before the asynchronous commit/transcription finishes.
   Closing on that acknowledgement lost the transcript. Stop now waits for commit
   acknowledgement and transcript completion before clearing.
2. Azure omits `event_id` on some `input_audio_buffer_commit_empty` replies after
   speech was already finalized. During the single pending client Stop commit,
   accept this acknowledgement; reject explicitly mismatched IDs and empty replies
   outside Stop. Pending transcription still must drain.

Twenty successful follow-up checks cover repeated two- and five-second pauses,
true sentence breaks, immediate Stop, and Stop after long idle silence. Four
initial idle-Stop failures remain in their original log directory; the corrected
four reruns are included in the validated follow-up report. The scorer also now
counts unexpected capitals throughout aligned text, so “Blue Notebook” cannot
escape the pause-boundary-only metric. Empty output on an expected-speech fixture
is a failed run.

Detailed artifacts:

- `.build/pause-bench/validated-comparison/report.md` — Handy and all four Azure profiles.
- `.build/pause-bench/validated-challenge/report.md` — final successful follow-up checks.
- `.build/pause-bench/azure-full/` — original service events and outputs.
- `.build/pause-bench/azure-challenge/` — first follow-up, including idle-Stop failures.
- `.build/pause-bench/azure-idle-fixed/` — successful idle-Stop reruns after the fix.

The credential-bearing process was closed after testing. No plaintext key file was
created. The final iOS build passes, along with 44 core tests and nine harness tests.
