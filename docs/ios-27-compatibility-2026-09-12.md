# Saywick on iOS 27 — September 12, 2026

## Physical-device results

Verified Jeff's iPhone 16 Pro reports iOS 27.0 (24A435). Tested existing Saywick
sources using installed Xcode 26.6 (17F113), linked against iOS 26.5 SDK. This is
runtime compatibility testing, not a rebuild using the iOS 27 SDK.

- App suite: 53 tests, 50 executed, zero failures. Native microphone capture,
  restarting capture, history, keyboard command/receipt regressions and settings
  migration passed. Two Apple Intelligence tests skipped because the system model
  was unavailable; one optional staged benchmark skipped.
- Real keyboard handoff: passed. Opened Settings search, used the Saywick keyboard,
  exercised inline More controls, opened Saywick, activated recording and ended
  the microphone session. This is a real extension test, unlike the in-process
  keyboard unit tests.
- Crash/handled-error collection after the upgrade: succeeded, no new reports,
  17 historical reports retained. Empty reports do not prove every flow works.
- Restored the preserved signed Release 1.0 (5) after the Debug test host.

Evidence: `.build/Coverage/ios27-phone-app.xcresult`,
`.build/Coverage/ios27-keyboard-handoff.xcresult`, and local logs named
`/private/tmp/saywick-ios27-*`. No application source changes were needed for
these tested paths. Existing release coverage is 78.24%; device testing is not
being combined with that earlier coverage report.

Still unverified: Apple Intelligence cleanup while its model is unavailable,
Bluetooth/car interruption behavior, prolonged background sessions, and an
end-to-end spoken passage inserted into another app. Microphone tests are not an
accuracy benchmark. Saywick preserves raw text and uses local rules when model
cleanup cannot run. The reason Apple Intelligence is unavailable was not exposed
by these tests; do not assume the update is still downloading its model.

## Keyboard-only recording findings

Apple's current custom-keyboard/open-access documentation does not add microphone
access, and the iOS 27 release notes/controller API inventory provide no new
public cold-start microphone capability for keyboard extensions. Full Access
continues to enable shared storage/network capabilities; it is not microphone
permission. `hasDictationKey` is an old API (iOS 8), and only disables the system
dictation key when set; it does not provide audio capture or start dictation.

Saywick's keyboard already sends recording commands through shared storage while
its containing app owns a ready microphone session. The current idle window is
two minutes. Its Start intent explicitly foregrounds the app when that session is
not ready. AudioRecordingIntent and Live Activities describe system-mediated
recording actions, but their existence alone is not evidence that a keyboard can
cold-launch microphone capture. Do not replace this with unsupported URL/responder
or background-audio workarounds.

The practical improvement to explore is reducing repeated activation during an
explicit recording session, with clear idle/session controls and safe interruption
recovery. Full cold-start recording entirely inside the keyboard is not a
capability established by this review.

## Relevant iOS 27 opportunities

1. Async audio activation/deactivation: Apple's current symbol metadata confirms
   `AVAudioSession.activate(options:completionHandler:)` arrives on iOS at 27.0
   (it previously existed on watchOS). This is the strongest responsiveness
   opportunity: our phone run logged an AVAudioSession main-thread hang-risk
   warning from synchronous session activation. Migrate audio ownership carefully
   with generation/cancellation checks; use the iOS 27 SDK and retain an older-OS
   fallback. This is a warning/opportunity, not an observed hang or test failure.
2. MetricKit: new Swift MetricManager AsyncStreams, memory-limit diagnostics for
   app extensions, termination categories and StateReporting context can make
   disappearing-keyboard reports substantially more useful. Our legacy MetricKit
   path is still the current implementation; do not claim these new reports are
   already integrated.
3. Background inference: iOS 27 restricts Neural Engine background access and
   introduces the continued-processing inference entitlement. Parakeet currently
   uses CPU/Accelerate, not the Neural Engine or Metal backend. Investigate this
   if changing inference backends; it grants computation access, not permission
   for a keyboard extension to capture audio.
4. Apple's Advanced Dictation Preview adds a new on-device dictation model and
   fixes formatting/contact-name behavior. It belongs to Apple's dictation UI;
   it is not documented as a custom-keyboard microphone API.
5. App Intents Testing can validate real system intent pathways with the new SDK.
   Useful for our Start/Stop actions, but does not itself expand permissions.

## Primary sources reviewed

- https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes
- https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard
- https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
- https://developer.apple.com/documentation/uikit/uiinputviewcontroller
- https://developer.apple.com/documentation/uikit/uiinputviewcontroller/hasdictationkey
- https://developer.apple.com/documentation/avfaudio/avaudiosession/activate(options:completionhandler:)
- https://developer.apple.com/documentation/appintents/audiorecordingintent
- https://developer.apple.com/ios/whats-new/

Read full release notes and keyboard articles, not just search snippets. Verified
API introductions using Apple's documentation JSON. A forum reply about cold
background recording was not authored by identified Apple staff and is not being
used as authoritative evidence of a new restriction or capability.
