# Keyboard refactor verification — 2026-09-09

The refactor is implemented and the signed Release app was installed on Jeff’s
paired iPhone 16 Pro. No production source changed between the final coverage run
and the Release build (verified against the saved SHA-256 source manifest).

## Changes

- Four authoritative dictation states with one pending operation, owned by
  `DictationController`; AppModel and the keyboard no longer independently drive
  recording phases or microphone retention.
- Real Cancel, Restart composed from Cancel/Start, separate save-only meeting
  completion, and generation guards against late asynchronous results.
- Single-writer recorder snapshots, command acknowledgments/rejections by ID,
  persistent insertion/dismissal receipts, and backward-compatible snapshot reads.
  App relaunch restores result identity without restoring microphone ownership.
- Explicit audio interruption/configuration/route/reset handling, on-device
  recovery storage, error cue plus persistent error text, and safe diagnostic fields.
- Audio conversion/archive and recording metadata workers, startup ordering,
  cancellable idle deadline, reduced inactive polling, and privacy manifests.

## Passing checks

| Check | Result |
| --- | --- |
| Core tests | 63 passed |
| Simulator app tests | 38 passed; 5 device/fixture cases skipped |
| Simulator UI tests | 5 passed; 3 physical-device cases skipped |
| iPhone app tests | 42 passed; 1 optional staged benchmark skipped |
| iPhone UI tests | 3 passed: app-started background meeting, Shortcut-started background meeting, keyboard handoff |
| Additional iPhone capture regression | 3 passed; actual microphone samples reached Parakeet and a nonempty WAV |
| Coverage aggregation tests | 2 passed |
| Signed Release build / signature verification | Passed |
| iPhone Release installation | Succeeded; bundle `com.yourname.localvoicekeyboard.app` |

Device testing also passed microphone retention/reuse, file-protection attributes,
Apple Intelligence cleanup, and the cancellation/interruption/recovery regressions.
The native capture check recorded three seconds and completed in 4.394 seconds;
this is a smoke measurement, not a long-recording performance benchmark.

## Coverage

Coverage is the union of executable source-line hits, never an average of target
percentages. Shared files are counted once. All first-party production Swift source
is accounted for; the ActivityAttributes file contains declarations only and has
zero instrumented executable source lines. Tests, tools, generated code, and
third-party dependencies are not in the denominator.

| Scope | Covered / executable | Coverage |
| --- | --- | --- |
| Overall, simulator alone | 2,562 / 3,382 | 75.75% |
| Overall, simulator + iPhone | 2,783 / 3,382 | **82.29%** |
| Refactored controller/state/keyboard/bridge group, combined | 1,003 / 1,203 | **83.37%** |

`make coverage` runs the core, simulator app/UI, and coverage-tool tests, writes a
source fingerprint manifest, and fails below 70% overall or for the refactored
group. It also fails when a production source file has no coverage accounting.
The simulator alone passes both gates; device results add execution evidence.

Local result artifacts:

- `.build/Coverage/run-20260909-224725/`: final simulator result, core JSON, source hashes, and coverage summary.
- `.build/Coverage/device-refactor-2.xcresult`: passing device app/UI suite.
- `.build/Coverage/device-native-capture.xcresult`: passing real-microphone pipeline regression.
- `.build/Coverage/final-combined.json`: combined line coverage, with per-file results.
- `.build/DeploymentDerivedData/Build/Products/Release-iphoneos/LocalVoiceKeyboard.app`: clean signed Release bundle (no test bundle).

Earlier failing runs are retained for diagnosis. They found timestamp precision,
startup ordering, and test assumptions about keyboard selection/Full Access; those
issues were fixed and the affected suites rerun. The physical capture test was
updated for explicit controller-owned hardware activation and now asserts real
samples, rather than merely calling the engine while the microphone is off.

## Remaining hands-on checks

A real car connection/disconnection, incoming phone call, first unlock after reboot,
and locked-screen/endurance recording were not reproduced during this session.
Simulated audio events and brief background tests do not prove those environments.
Confirm the error cue is audible on the particular car route; media volume or an
OS interruption can block playback. The error remains visible if sound is blocked.

The opt-in Parakeet benchmark had no staged fixtures and was reported as skipped.
Long-run memory/thermal performance and a complete VoiceOver/Dynamic Type device
review remain manual follow-ups, not passing automated results.
