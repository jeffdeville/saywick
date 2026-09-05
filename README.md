# Saywick

Your words. Your way.

An open-source iOS voice keyboard with swappable speech engines, local cleanup,
retained audio, and comparisons of different models on the same recording.
Built for personal testing on iPhone 16 Pro; targets iOS 26. This is a prototype,
not an App Store release. The Saywick App Store name has not been reserved.

## Features

- Microsoft MAI-Transcribe-2 upload transcription, Microsoft MAI Live streaming,
  on-device Apple SpeechAnalyzer, and on-device Moonshine Medium Streaming.
- Optional Apple Foundation Models cleanup, simple local formatting, or raw output.
- Explicit custom-word corrections, applied once after cleanup.
- Local history with original and final text, engine metadata, saved configuration,
  independent comparison runs, pinning, search, and deletion.
- Retained 16 kHz mono audio for playback and retranscription. Audio retention is
  enabled by default (7 days); text defaults to 30 days. Pins exempt both from expiry.
- Files import and a Share extension for audio from Voice Memos and other apps.
- Copy text, restore original/final text to the keyboard, export text or a Markdown
  comparison, and share text to Notes through the standard iOS share sheet.
- Start Dictation / Open History App Shortcuts; Start Dictation can be assigned to
  an iPhone Action Button. The shortcut opens the containing app to start recording.
- Live Activity / Dynamic Island recording status without transcript contents.
- Keyboard Stop & Insert, Clear/Restart, guarded Undo Insertion, held delete, and
  horizontal cursor movement by dragging on the space key. Not a full QWERTY keyboard.

## Privacy and retention

The containing app owns the microphone. The keyboard extension only exchanges
commands and current transcript text through an App Group; it never receives the
Azure key. Keys live in the app's device-only Keychain.

Local engines recognize on device after model downloads. Microsoft modes send
audio to your configured Azure resource. File comparisons using Microsoft require
explicit confirmation for each run. Cleanup and custom-word correction run locally.
There is no bundled API key or service subscription.

History lives in Application Support, excluded from backups, with iOS file
protection available after first unlock so background dictation can write safely.
Retained audio is a normalized recording, not necessarily the source file's original
encoding. Imports keep audio even when microphone retention is disabled. Retention
is enforced when History refreshes or the app starts, not by a guaranteed background
timer. Turning retention off only affects future microphone recordings.

Clear/Restart discards the current dictation's text/audio; insertion clears the
active keyboard session but leaves its saved history. Deleting a history entry
permanently removes its text and audio; Delete Audio Only preserves comparisons.
Shared audio waits locally in the App Group inbox until imported. Exported files
and copies shared to other apps are outside history's deletion/retention policy.
Keep only recordings you have permission to store or send to a provider.

## Build and install

1. Install Xcode with iOS 26 support and its simulator/device components. Add your
   Apple account in Xcode > Settings > Accounts.
2. Install XcodeGen (`brew install xcodegen`).
3. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`. Set your
   `DEVELOPMENT_TEAM`, unique `BUNDLE_ID_PREFIX`, and `APP_GROUP_IDENTIFIER`.
   The local file is ignored by Git. Never commit your credentials or profiles.
4. Run `xcodegen generate`, open `LocalVoiceKeyboard.xcodeproj`, and select the
   `LocalVoiceKeyboard` scheme. Those internal names remain for upgrade compatibility.
5. Connect/unlock your iPhone, trust the Mac, enable Developer Mode if prompted,
   and Run. Automatic signing applies to the app, keyboard, share extension, and widget.
6. Open Saywick and grant microphone access. Add the Saywick keyboard under
   Settings > General > Keyboard > Keyboards, and enable Full Access for the bridge.

Existing personal installs retain the old bundle/App Group identifiers so renaming
doesn't discard credentials, settings, or keyboard setup. A new distributor should
choose its own identifiers before the first public release.

## Azure configuration

Create a Speech resource in a region supporting your selected model (the prototype
was configured in East US). In Saywick's Azure connection section, enter the resource
root endpoint, such as `https://your-resource.cognitiveservices.azure.com/`, and a key
from Azure's Keys and Endpoint page. Save the connection before recording.

- MAI-Transcribe-2 records then uploads on Stop, requesting `clean` output using
  API `2025-10-15`. Spoken commands and live partials are unavailable in this mode.
- MAI Live uses Voice Live API `2026-04-10`, `mai-transcribe`, and a mandatory
  `gpt-5-nano` session model with automatic responses disabled. Microsoft does not
  identify the transcription alias as version 2. No assistant inference is requested.
- Voice Live pricing is separate from batch transcription pricing. Do not assume
  identical per-minute costs. The connection test checks session setup, not recognition.

References: [MAI transcription](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe),
[Voice Live](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/voice-live-how-to).

## Everyday dictation

Start listening in Saywick, switch to the destination app, select Saywick's keyboard,
and tap Stop & Insert. With a live engine, you can say “stop and insert”, “stop and
restart”, or “clear transcript”. Spoken command phrases remain in the original
recording/transcript for honest model comparisons; final insertion strips commands.

The keyboard's Open Recorder button may be refused by iOS. The supported fallback
is opening Saywick, or choosing Start Saywick Dictation in Shortcuts / Action Button
settings. This release doesn't promise invisible, background-only microphone startup.

Sessions stop at the selected 5/15/25 minute limit. Live modes also stop after 60
seconds without new recognized speech. Interruptions attempt to finalize and save;
if recognition fails, checkpointed text and retained audio are available in History.
Hard process termination can still lose the last in-flight audio/text segment.

## Compare recordings

Open History > a recording. Play the audio, select a model, then Run Selected Model.
Each attempt appends a new run, preserving earlier outputs and failures. Model labels,
cleanup choice, vocabulary, timestamps, and elapsed time are recorded with each run.
For local models the first comparison may download assets.

Use Reprocess Original to test current cleanup/custom words without retranscribing.
Unlike live dictation's fallback, a failed comparison cleanup is recorded explicitly
as an error. Use Original/Final in Keyboard to restore that exact text for insertion.

Comparisons preserve raw recognition text, including any spoken control phrases in
the audio; they never execute those phrases as commands. A live-session elapsed time
includes recording, so it is not directly comparable to a file run's processing time.
MAI Live file runs replay at real-time speed. No automated accuracy score is claimed.

## Audio import and export

Use History > Import Audio for a file in Files. For Voice Memos, share a **Rendered**
audio file to Saywick, open Saywick > History, and import it from Shared Audio. The
Share extension only queues the file; it doesn't transcribe or force-open the app.
If sharing isn't offered, Save to Files and use Import Audio.

Audio must be readable by AVAudioFile, nonempty, and no longer than 25 minutes.
The share inbox also limits individual files to 200 MB. Unsupported formats display
an error; successful imports are normalized locally before any model is called.
Long meeting recordings, diarization, and a standalone Voice Notes product are deferred.

## Custom words

One entry per line, saved automatically:

```text
Brecken = Breccan
Breccan
```

Corrections are case-insensitive whole-word/phrase matches. A single word enforces
capitalization. Longer matches win; substitutions don't cascade. This is deterministic
final-text correction, not acoustic training or fuzzy matching. Optional Apple model
cleanup can still change wording; compare it with the original before relying on it.

## Verification

```sh
make test
make ui-test
make build-device
```

The Makefile selects `/Applications/Xcode.app/Contents/Developer`. Override
`SIMULATOR` if your installed simulator isn't iPhone 17 Pro. Simulator demo mode
(`LOCAL_VOICE_SIMULATOR_DEMO=1`) emits synthetic transcripts without a microphone;
it does not verify cloud recognition or real-phone audio behavior.

See [device checks](docs/device-testing.md) and [roadmap](docs/roadmap.md).

## License

MIT. Moonshine remains a separately licensed dependency; its models and all cloud
services retain their own terms. No cloud credentials or model weights are published.
