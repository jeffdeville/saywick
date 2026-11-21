# Saywick 1.0 (5) — App Store preparation

## Release authority

After the required verification passes, contributors may prepare a local archive without further approval. For every release, obtain the owner’s explicit approval separately before each of these actions, in order:

1. Upload the build to App Store Connect.
2. Submit the release for App Review.
3. Release it publicly.

When the owner’s personal iPhone is available, automatically install the newest build from `main` that passed automated checks. Only builds from `main` qualify. After installation, run any [required physical iPhone verification](device-testing.md#required-physical-iphone-verification) before marking the affected change complete. The [device deployment procedure](crash-report-workflow.md#build-preserve-symbols-deploy) documents direct installation for crash fixes. General automatic delivery remains an implementation item.

## Candidate contents

- Default icon: approved red lips transitioning through purple into bright blue;
  the waveform stays blue to its end.
- Post-processing defaults to on-device Apple Intelligence. A one-time
  migration restores cleanup after the temporary release-preparation opt-out;
  later explicit choices, including Off, persist. The Pipeline → Post-processing picker exposes Off, local rules and
  optional Apple Intelligence modes. No Haiku or Anthropic service is used.
- Meeting recording UI, App Shortcut, engine and controller branches removed.
  Existing history files remain readable, including legacy meeting recordings.
  Historical schema fields and history helpers remain for data compatibility.
- Production hides internal opening diagnostics. An in-app privacy policy is
  accessible from the Privacy section.
- Version and build: 1.0 (5), consistent across app and extensions. iOS 26 minimum.

## Validation

Passing coverage: `.build/Coverage/run-20260911-213636/` — 78.24% overall,
86.40% refactor. All executed tests passed; device-only tests are skipped on the
simulator. Regression includes restoring on-device cleanup after the temporary opt-out, retaining
later explicit choices, and removal of the meeting entry point.

Archive: `.build/Release/Saywick-1.0-5.xcarchive` (archive succeeded).
Local App Store export was attempted with `Release/ExportOptions.plist`; it failed
because Xcode reported No Accounts, no iOS Distribution signing certificate, and
no App Store profiles for the app plus its three extensions. No upload or review
submission occurred. Development signing is separate from distribution signing.

Build 1.0 (5) restores on-device cleanup by default, with Off still available.
The passing coverage and matching symbols are preserved in
`.local-diagnostics/builds/cleanup-on-1.0-5/`. Physical audio/model regression
passed on the preceding build using the same native library; this settings-only
update has passing simulator migration and regression tests. Cross-app keyboard
and Bluetooth hands-on verification remain pending.

## Locally prepared materials

- `Release/metadata/en-US.json`: name, subtitle, keywords, description and proposed URLs.
- `Release/site/`: static support and privacy pages, ready for the proposed
  appstore.workhand.ai host. Not published. Direct support contact still required.
- `Release/ExportOptions.plist`: local App Store export options; destination is
  export, not upload.

## Remaining before submission

1. Sign into the paid team in Xcode and supply/create Apple Distribution signing
   and App Store profiles, then successfully export/validate the archive.
2. Create/verify the Saywick App Store Connect record, bundle identifiers and name
   availability. Complete pricing, availability, age rating, export-compliance,
   review contact and business/trader details. Do not invent answers to these.
3. Publish the support and privacy pages and add a real monitored contact. URLs
   in draft metadata are proposed, not active.
4. Capture final marketing screenshots at App Store-supported iPhone/iPad sizes
   from the real candidate, including dictation, keyboard and history. Do not use
   unit-test fixture screenshots or simulator-generated transcript samples as
   evidence of real recognition quality.
5. Complete Apple's archive validation once distribution signing is available.
   The native dependency has now been rebuilt from the pinned revision with
   matching dSYMs and a local-file-metadata privacy declaration. Run
   `python3 Tools/Release/verify_archive.py <archive> --version 1.0 --build 5`
   to verify bundle versions and app/extension/native symbol UUIDs. Local checks
   pass; they do not substitute for Apple's server-side validation.
6. Confirm App Privacy responses against actual shipping behavior. Audio/text and
   selected names are processed locally; network download providers receive
   normal connection metadata. Assess any diagnostics received through Apple
   and model hosting behavior before choosing the final privacy-label answers.
7. Complete physical keyboard handoff, background recording, audio-route-change,
   first-download and offline checks on supported devices. Previous keyboard UI
   automation could not initialize, so it is not counted as passing validation.

## Review notes draft

No account required. English speech recognition uses a one-time approximately
731 MB Parakeet model download. Open Saywick, permit microphone access, and start
a dictation to download/prepare the model. On-device Apple Intelligence cleanup is enabled by default.
Optional Apple Intelligence processing depends on system model availability.

Keyboard setup: Settings → General → Keyboard → Keyboards → Add New Keyboard →
Saywick. Basic typing works without Full Access. Full Access enables local App
Group sharing between the keyboard and the containing app; dictation audio is not
uploaded. The extension itself never opens the microphone. Start in Saywick,
switch to a text field in another app, select Saywick, and Stop to insert.

Keep keyboard ready uses the background audio mode for an explicitly activated
microphone session; it expires after two minutes idle between dictations. Use End
microphone session or the Stop recording shortcut to release recording. Live
Activities show recording state without transcript content.

## Apple references checked September 11, 2026

- https://developer.apple.com/app-store/review/guidelines/ (keyboard extensions and privacy)
- https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots
- https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
- https://developer.apple.com/app-store/review/ (support and privacy URLs)
