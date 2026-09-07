# Natural-recording attribution experiment

This experiment follows the synthetic pause benchmark. It uses one 312.36-second
archived Handy recording, chosen because its saved LLM output removed terminal
punctuation and lowercased the following word at three aligned boundaries.
Selection on those edits is deliberate and is not representative accuracy sampling.

Compare these outputs:

1. Saved Handy text before its LLM pass (may already have filler/vocabulary/stutter processing).
2. Saved Handy text after its LLM pass.
3. Fresh raw Parakeet replay with local text transformations disabled.
4. MAI Voice Live using Saywick's server1500 configuration and Stop handling.
5. The same MAI configuration with Handy's silence filter reapplied, preserving
   original wall-clock packet delivery times rather than accelerating the recording.
6. MAI-Transcribe-2 whole-file `verbatim`, with word timestamps.
7. MAI-Transcribe-2 whole-file `clean`, as a control for service-side formatting.

## Important controls and limitations

Handy archives the samples returned by its recording pipeline, which has already
applied its VAD filter. Original removed silence is unavailable in this file.
Reapplying the pinned filter drops 1.77 seconds of unique source samples and
re-emits 1.92 seconds of pre-roll, for a net length change of +0.15 seconds. This arm cannot establish
how the original microphone audio would have behaved without filtering.

The archive does not pin the historical model revision. The fresh replay uses the
known Parakeet Unified Q8_0 model and transcribe-cpp 0.2.0. It receives the saved
samples without another VAD pass.

Voice Live exposes the `mai-transcribe` alias, whereas the whole-file request pins
`MAI-Transcribe-2`. Differences may reflect backend version and inference mode;
whole-file results alone cannot prove a context-window cause.

There is no human reference transcript. The analysis reports word disagreement
and formatting differences, not word error rate or correctness. The three changed
boundaries include formatting and self-correction choices, not necessarily three
objectively incorrect periods. Full transcripts remain in ignored local artifacts.

## Reproduce/resume

The selected recording metadata and saved transcript pair are in
`.build/pause-bench/natural/history.json`; these private artifacts are not committed.
The filter export is generated with:

```sh
.build/PauseBenchHandy/release/handy-filter INPUT_WAV \
  .build/pause-bench/natural/filter.json \
  /Applications/Handy.app/Contents/Resources/resources/models/silero_vad_v4.onnx
```

Build the replay binary with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --scratch-path .build/PauseTests --product pause-bench-azure
```

Run the Azure arms under one 1Password authorization:

```sh
python3 Tools/PauseBench/with_azure.py natural .build/pause-bench/natural
```

This explicitly sends the selected recording to the configured Azure resource.
It makes two real-time streaming requests and two whole-file requests concurrently.
Keys remain in memory. No new LLM cleanup request is made; Handy's stored result
is reused. To generate the local comparison report after outputs arrive:

```sh
python3 Tools/PauseBench/natural_report.py .build/pause-bench/natural
```

The report includes every full output, excerpts around the three selected
boundaries, pending/failed paths, and the interpretation limits above.

## Current local result

The fresh Parakeet replay reproduced all 465 words of the saved pre-LLM transcript
with zero word-level disagreement, including the three selected terminal-punctuation
boundaries. The saved LLM pass changed those boundaries to a comma and two em
dashes and lowercased the next words. This directly attributes these particular
formatting differences to the LLM stage rather than better raw recognition.

The subsequent authorized retry completed all four Azure paths successfully.
The credential-bearing session was closed afterward. The report now contains all
seven outputs, including the two saved Handy stages and fresh Parakeet replay.

## Completed Azure comparison

| Path | Conventional terminal punctuation marks (excluding ellipses) | Ellipses |
|---|---:|---:|
| Fresh raw Parakeet | 19 | 0 |
| MAI streaming | 38 | 6 |
| MAI streaming, filter reapplied | 36 | 4 |
| MAI whole-file verbatim | 27 | 0 |
| MAI whole-file clean | 25 | 0 |

Counts are descriptive, not correctness scores. At exact adjacent word matches,
streaming inserted 12 conventional terminal boundaries absent from whole-file
verbatim; the re-filtered stream inserted nine. Streaming and whole-file verbatim
had only five word edits between them across this recording. Examples of the
streaming segmentation include “you can't. Skip things.” and “failed to do that.
With the coding.” Whole-file recognition kept those phrases joined.

At the three selected boundaries:

- “project plan / force him”: raw Parakeet and both streaming arms used a period;
  both whole-file modes used a comma, like Handy's LLM pass.
- “together / no”: raw Parakeet, both streaming arms and whole-file verbatim kept
  a period. Handy's LLM used an em dash; whole-file clean omitted the separator
  but retained the capital N.
- “research / like”: raw Parakeet used a period; both MAI streaming and whole-file
  arms used a comma. Handy's LLM used an em dash.

MAI's word timestamps estimate the corresponding archived-audio gaps as 3,121 ms,
2,041 ms and 81 ms. The last is not a long silence in this representation, so
silence duration cannot explain every difference. These timestamps are model
estimates, not human measurements or the original pre-VAD microphone timeline.

The best-supported updated explanation is a combination: MAI's deployed streaming
path fragments natural phrases more aggressively, while Handy's LLM further
revises the raw Parakeet output. Whole-file MAI shows a promising recognition-side
context/model difference without an LLM rewrite. The experiment does not isolate
context from model revision, nor establish a general accuracy ranking. Reapplying
VAD did not eliminate the observed segmentation behavior, and the original
unfiltered audio remains unavailable.

Results: `.build/pause-bench/natural/report.md`. Raw service responses, packet
schedule, hashes and whole-file word timestamps are retained alongside it. No app
behavior or phone installation was changed in this attribution experiment.

## Follow-up iPhone engine experiment

The same archived audio was subsequently replayed through Saywick's experimental
Parakeet engine on iPhone 16 Pro. The ARM dot-product CPU build reproduced Handy's
raw output exactly, including all 465 words and its 19 terminal punctuation marks.
This supports using the same model/runtime to reproduce that raw quality locally;
it does not establish superiority on a representative or human-labelled corpus.
The first CPU run accumulated 99 seconds of input backlog. Enabling Apple
Accelerate preserved the exact output and reduced maximum backlog to 0.50 seconds:
the 312.36-second recording finished in 312.65 seconds with realtime pacing.
This supplies enough throughput for this replay, while background microphone
behavior and battery endurance remain unmeasured. See [the iOS experiment](parakeet-ios.md).
