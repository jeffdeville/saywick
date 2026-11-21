---
clny_guidance:
  version: "0.4.0"
  reviewed: 2026-11-20
  responsibilities:
    - id: ios-product
      interview: complete
    - id: public-information
      interview: complete
---

# Saywick engineering guide

| Owner-confirmed responsibility | Ambition | Interview progress |
| --- | --- | --- |
| iOS voice keyboard and recorder for people dictating and working with their saved dictations | Thorough | [Product scope and deferred features](#product-promises). [Change authority recorded](#product-change-authority). [Physical iPhone verification required](device-testing.md#required-physical-iphone-verification) for changes to microphone capture, background recording, or keyboard handoff. [Release approvals and automatic personal-phone delivery adopted](app-store-release.md#release-authority). The latest passing build from `main` qualifies when the iPhone is available. Routine product monitoring declined because the owner does not need it. Revisit if the owner requests monitoring. See [on-demand crash triage](crash-report-workflow.md). [History retention](#history-retention) sets one seven-day maximum for transcripts and recordings, including imports. The first cleanup after upgrade applies the limit to existing history, including pinned items. Transcripts and recordings are excluded from device backups. [Monthly upstream review adopted](#speech-dependency-review). [Paid cleanup authorization recorded](#product-promises). |
| Public information and support for prospective and current Saywick users | Starter | [Support promise adopted](../Release/README.md#support-promise). A working contact is pending. [Draft change authority adopted](../Release/README.md#draft-changes). [Prepublication checks adopted](../Release/README.md#before-publication). [Owner approval required for each publication](../Release/README.md#publication-approval), including routine corrections. [Check the support contact daily after public launch](../Release/README.md#after-public-launch). Each release’s [changelog entry](../Release/CHANGELOG.md) triggers relevant site and listing updates. [Support triage recorded](../Release/README.md#support-triage). A website form will deliver reports to the private Slack support channel. The form accepts bug reports without an email address. Users may leave one for a reply. Reports and optional email addresses follow the Slack workspace’s normal retention policy. The owner-controlled form handler sends submissions directly to Slack. [Optional screenshots and diagnostic uploads adopted](../Release/README.md#optional-support-attachments). |

## Component map

This charter was established against a local release-candidate working tree. Candidate observations below can differ from the implementation on the default branch. Observed practices have unexamined standing unless an existing decision says otherwise.

| Area | What it serves | Evidence and reading route |
| --- | --- | --- |
| Sources/App, including Engines, PostProcessing, Views and Resources | Dictation, model setup, transcript cleanup and retained history. | [App model](../Sources/App/AppModel.swift), [user workflows and retention](../README.md), [native runtime](parakeet-ios.md) |
| Sources/KeyboardExtension, Shared, StatusWidget | Users type or dictate in another app, see recording status, and stop recording | [Keyboard session](keyboard-session.md), [shared store](../Sources/Shared/SharedContainerStore.swift), [activation diagnostics](activation-diagnostics.md) |
| Sources/VoiceKeyboardCore, Tools/Parakeet, Tools/PauseBench | Shared dictation logic and developer evaluation of transcription quality. Historical provider helpers also serve the benchmark executables | [Package targets](../Package.swift), [pause benchmark](pause-benchmark.md), [natural transcription comparison](natural-transcription-comparison.md). HandyRunner's Cargo.lock pins benchmark dependencies |
| Config, project.yml, LocalVoiceKeyboard.xcodeproj, Makefile | Configure, generate and build app and extension targets | [Build and install](../README.md#build-and-install), [target definitions](../project.yml), [build commands](../Makefile). Xcode project files are generated |
| Tests, Tools/Coverage, Tools/Diagnostics | Core smoke and unit checks, app and UI checks, device diagnostics and coverage | [Device checks](device-testing.md), [crash workflow](crash-report-workflow.md) |
| Tools/Release, Release/ExportOptions.plist, LICENSE | Prepare and verify the distributable product and its notices | [Release checklist](app-store-release.md), [license](../LICENSE), [runtime notices](../Sources/App/Resources/Parakeet-Licenses.txt) |
| Release/metadata, Release/site, Design/AppIcon and app icon asset | Explain Saywick to prospective users, publish privacy and support information, and supply product artwork | [Release material status](../Release/README.md), [listing draft](../Release/metadata/en-US.json), [icon guide](app-icon.md). Listing and site serve public information and support. The icon also ships in the iOS product |
| docs | Contributor procedures, experiments, comparisons, roadmap and dated verification records | [Device procedure](device-testing.md), [roadmap](roadmap.md). Dated reports describe their respective runs |
| Local workspace directories | Developer-only build output, package state, diagnostics, editor history and indexing | [.gitignore](../.gitignore) covers .build, .swiftpm, .local-diagnostics, .history, .serena and Finder metadata. Git metadata and generated dependency trees are outside the product inventory |

## Further evidence

The [research notes](research.md), [workflow comparison](spokenly-comparison.md), and [icon guide](app-icon.md) cover investigation and design history.

## Product promises

Fresh installs default to Faithful cleanup. Every upgrade must preserve the user’s saved cleanup choice, including Off. The owner confirmed both requirements on November 20, 2026.

Saywick must always transcribe audio on device. Cloud cleanup requires an explicit user selection, including when a local processor is unavailable. Selecting OpenAI cleanup authorizes subsequent cleanup requests using the user’s API key, which may incur charges. Authorization ends when the user turns cleanup off or selects another mode. No per-request confirmation is required. The local release candidate includes an OpenAI cleanup mode. The [privacy and retention guide](../README.md#privacy-and-retention) describes the text sent with that selection.

Speaker identification and meeting summaries are outside the current product scope. The owner is interested in researching both and has deferred implementation. Revisit if research leads the owner to prioritize either feature. The release candidate retains legacy recordings. Restoring dedicated meeting recording is deferred until the owner revisits it. Existing imported history is subject to the same retention policy as other recordings.

## Product change authority

A contributor may implement a fix without asking the owner again when the behavior is already approved and the fix stays within the existing architecture. Preserving a saved Off choice on upgrade is one example. Architectural decisions follow the owner’s separate independent-review requirement.

## History retention

The owner chose to drop pinning and set one seven-day retention maximum for transcripts and all recordings stored in Saywick, including imported audio. The same limit applies to both, with no separate recording retention period. On the first cleanup after upgrade, delete all transcripts and recordings older than seven days, including imported audio and previously pinned items, regardless of the prior retention setting. Deletion proceeds without a one-time export window. Keep transcripts and recordings, including imported audio stored in Saywick, out of device backups. Restoring Saywick history from a device backup is outside the product scope.

The current [history store](../Sources/VoiceKeyboardCore/TranscriptHistory.swift) still skips pinned entries during expiry and deletes the entire entry, including attached audio, when its text expires. The [current user guide](../README.md#privacy-and-retention) describes the existing behavior. Removing pins and changing retention are pending product changes.

## Speech dependency review

Once a month, review [Handy releases](https://github.com/cjpais/Handy/releases), its speech model recommendations, and relevant [runtime changes](https://github.com/handy-computer/transcribe.cpp). Compare them with Saywick’s [pinned native runtime](../Tools/Parakeet/bootstrap.sh) and [verified model](../Sources/App/Engines/ParakeetModelStore.swift). Record the releases covered, which changes could help the iOS app, and what evidence would justify adopting them. The monthly review authorizes research and reporting only.

## Open findings

- The local release candidate’s app settings initializer implements the fresh-install default. Its one-time migration can still replace a saved Off choice with Faithful when the earlier opt-out migration flag is set. Preserving Off on this upgrade path is an outstanding implementation gap.
- Optional OpenAI cleanup uses the user's key and sends transcript content and relevant vocabulary to the provider. The privacy draft describes that transfer. Recordings excluded from backup can be permanently lost through expiry or deletion.
- The [device checklist](device-testing.md) includes checks for four transcription engines and Microsoft comparisons from an earlier product version. Its physical-device checks for microphone capture and background operation remain relevant.
- The local build 1.0 (5) candidate removed dedicated meeting recording entry points. The default branch still includes an earlier implementation.
- The release README identifies the listing and site as drafts and calls for a real support contact before publication. Publication status has not been independently verified.
