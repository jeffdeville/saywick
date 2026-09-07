# Saywick

Your words. Your way.

An open-source iOS voice keyboard with on-device Parakeet transcription, local
cleanup, a basic typing keyboard, and retained audio for playback and retranscription.
Built for personal testing on iPhone 16 Pro; targets iOS 26. This is a prototype,
not an App Store release. The Saywick App Store name has not been reserved.

## Features

- On-device Parakeet English transcription after a one-time 731 MB download.
- Optional faithful punctuation/capitalization cleanup with Apple Intelligence,
  opt-in paragraphs and bullets, simple local formatting, or raw output.
- Word-list dictionary and optional exact corrections, applied before cleanup.
- Local history with original and final text, engine metadata, saved configuration,
  independent comparison runs, pinning, search, and deletion.
- Retained 16 kHz mono audio for playback and retranscription. Audio retention is
  enabled by default (7 days); text defaults to 30 days. Pins exempt both from expiry.
- Files import and a Share extension for audio from Voice Memos and other apps.
- Copy text, restore original/final text to the keyboard, export text or a Markdown
  comparison, and share text to Notes through the standard iOS share sheet.
- Start Dictation, Record Meeting, and background Stop Recording App Shortcuts;
  assign them to the Action Button, Back Tap, or a custom Shortcut.
- Meeting audio recording up to four hours, with local transcription afterward.
- Live Activity / Dynamic Island recording status and a Stop button, without transcript contents.
- Keyboard Stop & Insert, Clear/Restart, guarded Undo Insertion, held delete, and
  horizontal cursor movement by dragging on the space key. Basic QWERTY typing, Shift, numbers, and punctuation work without Full Access.

## Privacy and retention

The containing app owns the microphone. The keyboard extension exchanges commands
and current transcript text through an App Group when Full Access is enabled.
Typing needs neither Full Access nor a model download.

Parakeet recognizes English on device after its one-time model download. There are
no cloud transcription engines, credentials, accounts, or service subscriptions.
Cleanup and custom-word correction also run locally. Existing History retains its
original engine labels; old recordings can be transcribed again with Parakeet.
Legacy provider protocol helpers under VoiceKeyboardCore support the historical
command-line benchmarks only; the iOS app has no provider client or upload path.

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

## Everyday dictation

Keep keyboard ready is enabled by default. Start listening in Saywick once, then
switch to the destination app and select the Saywick keyboard. Tap **Stop & Insert**
to finish that dictation, then **Dictate** for the next one without leaving
the destination app. Each dictation has its own transcript and History entry.
The keyboard opens in dictation mode. **ABC** switches to typing; **Voice** returns.
One primary button reflects readiness, recording, and finishing. **Open Saywick**
requests a URL handoff to activate the microphone in the app. If iOS rejects the
request, inline instructions explain the Shortcut fallback. More expands inline.

After each completed dictation, readiness lasts **2 minutes idle**. Starting a new
dictation cancels that countdown; the next completed dictation starts a fresh one.
Active recordings are not cut off at two minutes. The microphone indicator remains
on while ready, but incoming audio is discarded before copying, saving, or inference.
**End** releases the microphone immediately. Expiry preserves the finished transcript.
Hiding the keyboard does not reset or cancel the idle deadline. Sessions are not
restored after relaunch. Reactivate in Saywick or with Start Dictation in Shortcuts.

Turn off Keep keyboard ready before starting if you want the previous single-recording
behavior: Stop releases the microphone, and hiding or switching keyboards after using
the Saywick keyboard stops recording after a 3-second grace period.

The keyboard's Start button starts another dictation only while the microphone is
ready. Otherwise it explains how to activate Saywick through the app or Shortcuts;
it never launches the containing app. History playback asks you to end readiness first.

## Background activation and meetings

In Saywick, tap **Set up background dictation** to grant microphone access and
prepare Parakeet once. Enable Live Activities in iOS Settings for Saywick. Then
choose **Start dictation** in Shortcuts/Action Button settings. The intent uses
Apple's AudioRecordingIntent and LiveActivityIntent. Cold microphone starts open
Saywick using the system's dynamic foreground continuation: direct background
activation failed on the test iPhone. Dictation can restart without opening the app
while its microphone is still ready. A missing model produces setup instructions
instead of downloading weights during a shortcut.

**Record meeting** in the app or **Start Saywick meeting** in Shortcuts (which opens
Saywick to activate the microphone) records
microphone audio straight to local storage, without running transcription. It does
not require Parakeet to be downloaded. Meetings always retain audio (even when
ordinary dictation audio retention is off), and follow History's normal expiry/pin
settings afterward. Recording ignores keyboard dismissal and the dictation idle
timer, and stops at four hours. PCM16 mono audio uses about 115 MB per hour.

Stop through the app, the Live Activity/Dynamic Island Stop button, or **Stop Saywick
recording** in Shortcuts. The Stop shortcut also releases dictation readiness.
Use History > recording > **Transcribe with Parakeet** afterward, keeping Saywick
open while file transcription runs. Meeting mode does not identify speakers or
produce meeting summaries. It captures the microphone, not other apps' call audio.

The recorder and command/interruption observers are process-owned, so they do not
rely on a SwiftUI screen task remaining alive. Background starts require microphone
permission already granted and a successfully created Live Activity. Failed starts
surface a Shortcut error and release audio resources. A recording is never resumed
automatically after a process termination or interruption.

## Saved recordings and imports

Open History > a recording to play audio, copy text, restore text to the keyboard,
or **Transcribe with Parakeet**. Each run preserves earlier results and settings.
**Reprocess original** applies current local cleanup and custom words without
transcribing again. Existing recordings from retired engines remain readable.

Use History > Import Audio, or share rendered audio from Voice Memos to Saywick.
The Share extension queues audio locally; import it from Shared Audio in History.
Imports retain audio regardless of the microphone retention preference. Files must
be readable, nonempty, and no longer than four hours; shared files are limited to
1 GB. Speaker diarization remains outside the current scope.

## Final text cleanup

Live text is a draft. Speech engines may interpret a thinking pause as a sentence
boundary; Saywick preserves that original output in History. Choose **Faithful
cleanup (Apple Intelligence)** to repair punctuation and capitalization after Stop,
using the surrounding words to reconsider those boundaries. Existing cleanup
selections are preserved; new installs default to Faithful cleanup. Raw and Fast
local rules do not perform semantic repair.

Faithful cleanup preserves every word in order, including repetitions and fillers.
**Paragraphs & bullets (Apple Intelligence)** additionally permits layout for clear
lists or topic changes. Neither mode summarizes or rewrites wording. Formatting
preferences cannot override word preservation. Custom-word corrections run
once beforehand and may intentionally replace words.

Long transcripts are split into disjoint edit targets with read-only context from
both neighboring sections. Each section uses a fresh model session; context is
never inserted into the output. A lexical check rejects added, omitted, reordered
or substituted words, changed numeric tokens, or lowercased acronyms. This checks
word preservation, not the correctness of every punctuation or proper-name choice.

If the model is unavailable, a request fails, or an edit fails validation, live
recordings fall back to basic cleanup for the original transcript and show the
reason. History comparison runs report the failure instead. No partial model edit
is published after an error. Very long individual words or formatting preferences
may also trigger this fallback. Long recordings require multiple model requests
and take longer to finish. Recognition segmentation settings remain unchanged
pending comparisons on the same recorded audio.

## Custom words

One entry per line, saved automatically:

```text
Brecken = Breccan
Breccan
```

Standalone words use conservative local spelling/sound matching, including short
word splits such as `say wick` → `Saywick`. Ambiguous candidates stay unchanged;
common name/word collisions such as may and will are protected. Exact aliases
remain available for persistent errors. Correction runs before cleanup and does
not train or bias Parakeet's recognizer. The original transcript remains in History.

**Add names from Contacts** opens Apple's selection picker, then a review of the
names to add. Only selected names are stored locally, with duplicates removed.
Edit or delete entries directly in the word list.

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

MIT for Saywick. Parakeet weights and its native runtime retain their respective
licenses; notices ship in Sources/App/Resources/Parakeet-Licenses.txt. Model weights
are downloaded, not committed to this repository.

## Raw pause regression tests

The historical [pause benchmark](docs/pause-benchmark.md) compares Handy and retired
Microsoft profiles. It is developer tooling, not part of the shipping app.

See [the Spokenly comparison](docs/spokenly-comparison.md) for published workflow differences.

## Parakeet runtime

Saywick uses Parakeet Unified English with Handy's Q8_0 model and pinned native
runtime. All existing installs now select Parakeet for new audio.
On a fresh checkout, run `make parakeet-bootstrap` before generating or building
the Xcode project (requires CMake and Xcode). See [the iOS experiment](docs/parakeet-ios.md)
for model details, limitations, and the opt-in phone benchmark.
