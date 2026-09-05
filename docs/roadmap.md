# Saywick roadmap

## Current implementation

Personal dictation, local audio retention, transcript history, independent model
comparisons, local cleanup, custom vocabulary, Files/share intake, basic export,
Action Button-compatible shortcut, Live Activity status, and keyboard recovery.

## Before an App Store release

- Confirm/reserve the Saywick listing name; preliminary public searches are not clearance.
- Audit dependencies/model redistribution and cloud-provider terms.
- Exercise every engine on real audio, including background interruptions and low storage.
- Test share intake on Voice Memos, Files, and third-party messaging apps.
- Test Action Button startup, Live Activities, VoiceOver, Dynamic Type, and keyboard editing.
- Add App Store assets, privacy policy, privacy disclosures/manifests as applicable,
  production identifiers, onboarding, and a release/distribution process.
- Improve session recovery after force-quit and audio-route changes.
- Add an explicit evaluation corpus and reference transcripts for accuracy scoring.
- Consider a direct Control Center control and a richer dictionary correction UI.

## Deliberately deferred: Voice Notes / meeting recorder

A separate recording workspace could later add long recordings, projects/folders,
speaker diarization, summaries, recording titles, Markdown templates, and richer Notes
exports. Reuse audio assets and immutable transcript runs from the current history
layer. Do not turn short keyboard dictation into a meeting recorder implicitly.

No meeting capture, automatic summaries, meeting bots, cloud sync, or Notes-account
integration is implemented in the current work. Standard iOS text sharing is not
direct database access to Apple Notes.
