# iPhone 16 Pro test checklist

## Saywick history release

- Confirm the renamed app upgrades in place without losing Azure settings.
- Record with each of the four engines; play the retained audio after Stop.
- Test Clear/Restart midway; discarded words must not remain in retained audio or final text.
- Force a network error; recover checkpointed text and retry the retained audio.
- Compare a single file with all engines; original runs must remain unchanged.
- Test local reprocessing, original/final keyboard restoration, text/Markdown export,
  Save to Notes through sharing, and audio sharing.
- Import Voice Memos Rendered audio through Share and through Files; confirm no cloud
  request happens until a Microsoft comparison is explicitly confirmed.
- Cancel a long import/comparison and verify the source recording is preserved.
- Test pins, audio-only deletion, full deletion, retention settings, and low storage.
- Assign Start Saywick Dictation to the Action Button; check microphone indicator,
  Live Activity, interruption recovery, silence timeout, and maximum-duration stop.
- Test Undo Insertion immediately, then after editing/moving to a different text field;
  unsafe undo must be disabled. Test held-delete and space-key cursor dragging.

The original checklist below predates the Saywick rename; Local Voice refers to Saywick.

Run this checklist on the physical phone before changing the default engine. Simulator results do not answer the memory, thermal, microphone, background, or keyboard questions.

## Simulator checks

- Run the `LocalVoiceKeyboardUITests` scheme test with `LOCAL_VOICE_SIMULATOR_DEMO=1` supplied by the test target.
- Confirm the deterministic partial transcript, finalization, Foundation Models cleanup, and ready-to-insert state.
- Add Local Voice under Settings > General > Keyboard > Keyboards, enable Full Access, and confirm the extension renders the shared result.
- Launch without demo mode and confirm a real engine reports that microphone capture needs a physical iPhone instead of terminating in Simulator Core Audio.
- Treat successful model preparation as an integration check only; do not use Simulator latency or accuracy as a device benchmark.

## Installation and signing

- The app and keyboard extension both sign with the same Team.
- The configured App Group appears on both targets.
- The app launches after installation and requests microphone permission.
- Local Voice appears under Settings > General > Keyboard > Keyboards.
- Full Access is enabled and the keyboard reports “Keyboard bridge ready.”

## Functional smoke test

For each engine and cleanup option:

1. Start listening in the app.
2. Dictate ten seconds containing punctuation, a proper noun, a number, and a self-correction.
3. Verify partial text changes rather than repeatedly appending duplicate words.
4. Stop in the app and verify finalized/cleaned output.
5. Start again, switch to Notes, select Local Voice, and use Stop & Insert.
6. Verify exactly one insertion and sensible spacing at an existing cursor.
7. Turn on Airplane Mode after model installation and repeat.

## Comparative corpus

Use the same recordings for every engine:

- 20 short messages (5–15 seconds).
- 10 longer notes (60–120 seconds).
- quiet room, street noise, car cabin, and speaker at arm’s length.
- names and domain terms you actually use.
- whispered/quiet speech.

Record a human reference transcript. Report word error rate only after applying the same case and punctuation normalization to every engine. Keep raw hypotheses for qualitative review.

## Measurements

- Cold model preparation time.
- Warm start time.
- Time to first partial.
- Time to first finalized text.
- Phrase-end to final result when the engine exposes it.
- Cleanup wall time.
- Peak memory in Xcode’s memory gauge.
- Battery change over 15 minutes of continuous dictation.
- thermal state at 5, 10, and 15 minutes.
- word error rate on the shared corpus.
- number of duplicate, dropped, or rewritten words in partial output.

## Background stress

- Switch among Notes, Messages, Mail, and Safari while recording.
- Lock and unlock the phone during an active session.
- Receive a phone call or start other audio and verify understandable recovery.
- Enable Low Power Mode and repeat Stop & Insert.
- Leave the app suspended for five minutes, then try the keyboard control.

The app should be honest when iOS suspends it: show that the recorder is unavailable and offer to open the app. Do not attempt silent microphone capture or indefinite background execution outside an active, user-visible recording session.
