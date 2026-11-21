# Saywick release reliability audit — September 11, 2026

## Result

Build 1.0 (4) passes the complete simulator/core coverage gate: 76.98% overall
(2,825/3,670 executable lines), 85.59% in the refactored group. The prior candidate
was 76.35% / 85.65%. No thresholds or exclusions were relaxed. Coverage is a
line-execution measure, not proof that every device scenario works.

Evidence: `.build/Coverage/run-20260911-213001/` contains source SHA-256 hashes,
core coverage, the Xcode result bundle and summary. There were 63 passing core
tests, 53 app tests with five explicit device/model-dependent skips, and six UI
tests with one device-only skip. Seven diagnostic collector tests and two coverage
collector tests pass. `git diff --check` passes. Final archive builds without
Swift compiler warnings; the metadata tool's no-AppIntents warning for an
extension remains informational. Deep code-signature verification passes.

## Findings fixed

- History could delete an entry while recording or comparing, and a missing
  comparison destination silently reported success. Deletion is now guarded,
  retention protects the working entry, and missing destinations report failure.
  Regressions cover both races and stale entries.
- Native recording cancellation could consume queued audio after cancellation.
  Cancel now cancels its consumer and checks cancellation before processing each
  queued buffer. Ordinary Stop still drains captured audio for final text.
- Model download integrity and concurrency lacked inexpensive deterministic
  coverage. Injected storage/download dependencies now test concurrent callers,
  checksum/cache validation, HTTP failure, retry, and offline reuse without
  downloading the production 731 MB model.
- Several recoverable errors only appeared in UI, or were discarded by polling.
  Recording, model setup, bridge, history, Share and Live Activity errors now
  emit OSLog error events and bounded local diagnostic records.
- Added MetricKit crash/hang/CPU/disk diagnostic capture when Apple delivers it,
  including available past payloads at startup. It does not replace Apple's
  crash reporter, install signal handlers, or promise immediate delivery.
- Added Privacy → Export diagnostics. Error records exclude transcript/audio,
  localized error descriptions, paths, userInfo and contact names. Unknown
  domains are hashed; build/version and operation identify the failure context.
  Storage is protected, excluded from backup, bounded and deduplicated. Tests
  cover redaction, corrupt-log recovery, limits and invalid payload rejection.
- Crash collection missed Share/Status extension names and assumed every stack
  index was valid. Filtering and incomplete-stack handling now have regressions.
  Daily collection also retrieves only diagnostic JSON from shared storage,
  deduplicates individual events and reports collection failures. Its tests
  ensure transcript files and unsafe paths are not copied.
- Contacts picker delegates accessed SwiftUI state outside declared main-actor
  isolation. UI callbacks now hop explicitly to the main actor.

Review covered the session/controller flow, audio ownership and cancellation,
model download/cache, history persistence and deletion, keyboard command bridge,
extensions, UI actor isolation, diagnostics pipeline, tests and release packaging.
Existing app/icon/meeting-mode changes were preserved. No speculative architecture
rewrite or third-party remote telemetry service was introduced.

## Release evidence and remaining gates

Archive: `.build/Release/Saywick-1.0-4-validated.xcarchive`. Candidate and matching
app/extension/native dSYMs are retained under `.local-diagnostics/builds/audit-1.0-4/`.
Source fingerprints match the coverage report and archive. Installed at 21:33 EDT
and launched at 21:34 EDT on Jeff's iPhone. Installation/launch are separate from
real keyboard and Bluetooth verification. Physical app tests then passed: 53
tests, one optional benchmark skipped, zero failures. This includes native
microphone capture, capture reuse after Stop, and Apple Intelligence processing.
Evidence: `.build/Coverage/audit-phone-1.0-4.xcresult`. The Release candidate was
restored at 21:33 EDT after the Debug test host finished.

Phone collection succeeded: 17 known crashes, zero new reports. The older
installed build had no handled-error diagnostics yet. Empty collection does not
prove absence of errors. For future triage use `docs/crash-report-workflow.md`.

App Store export was attempted again and failed: Xcode reports No Accounts,
missing iOS Distribution certificate and missing distribution profiles for all
four bundle IDs. Nothing was uploaded or submitted. Support/privacy pages remain
local and need a real support contact and publication. Final screenshots,
App Store Connect metadata/privacy answers, physical handoff/background/Bluetooth
checks and Apple's archive validation remain release gates listed in
`docs/app-store-release.md`.

## Apple guidance

- https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs
- https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information
- https://developer.apple.com/documentation/os/generating-log-messages-from-your-code
- https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload

## Native dependency and packaging verification

Rebuilt CTranscribe from pinned upstream revision
`93151602c670f0dbf6703b1d87a8822f87581a0b`, preserving CPU-only execution,
Accelerate, dot-product support and Release optimization. The build now emits
and packages native dSYMs. Xcode includes them in the archive; native binary and
dSYM UUIDs match, and `dwarfdump --verify` reports no errors. The native sources,
build tools and exact package hashes are preserved with the candidate. Coverage
runs now record `native.json`, preventing confusion between tested binaries.
The collector now recognizes and symbolicates CTranscribe frames too.

The source/import audit found monotonic clocks for interval timing, sysctl for
CPU capabilities, and filesystem metadata for local backend discovery. Added
CTranscribe's privacy manifest declaring C617.1 for local file metadata. No
tracking or remote data collection was introduced. Upstream native compilation
retains non-fatal warnings about unused variables and the older Accelerate
interface. Apple archive validation remains pending distribution signing.

The audit also found generated plists hardcoded build 1, despite incrementing
Xcode build settings. All four shipping plists now reference the version/build
settings. The new archive verifier checks actual bundle metadata, all dSYM UUIDs
and native privacy packaging. It rejects the earlier incorrectly numbered
archive and passes the final 1.0 (4) archive. Earlier folder names containing
"1.0-2" or "1.0-3" were candidate labels, not verified embedded build numbers;
they must not be used to identify crash versions without inspecting the plist.

Final device run: 52 executed tests passed, one optional benchmark skipped.
Final simulator/core gate passed: 76.98% overall, 85.59% refactor. Differences
between repeated line coverage runs reflect asynchronous/UI execution paths;
all runs exceed the required 70%, with no threshold changes.
