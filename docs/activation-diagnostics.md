# Unexpected app foregrounding

Source review found no timer, keyboard refresh, transcription callback, or
recording-completion path that requests app foregrounding. Xcode device tests
do launch the app, including when a previously locked phone becomes available.
The remaining normal entry points are the Start keyboard button,
App Shortcuts (including an Action Button or automation invoking them), and
taps on the recording Live Activity / Dynamic Island.

Two concrete lifecycle issues were corrected without claiming either proves
spontaneous foregrounding:

- Untimestamped shortcut flags could survive indefinitely and start recording
  on a later launch. Requests now expire after 30 seconds, are consumed once,
  and execute only while the app is active. Legacy flags are discarded.
- A Live Activity could outlive a crashed recording process. On app startup,
  activities not owned by the current recording manager are dismissed.

The keyboard's Start button opens `saywick://start?source=keyboard` to start
recording, only after an explicit tap while the keyboard is visible, attached to
a window, and has Full Access. It uses SwiftUI's environment openURL action in a
hosted button, replacing a silent optional extensionContext request. A rejected
request shows a fallback instruction. The Live Activity link only opens the
recorder screen. The explicit Start Dictation shortcut starts recording.

URL-opening reference: https://keyboardkit.com/blog/2024/09/11/ios18-breaks-selector-based-url-opening
Physical keyboard-to-app navigation still requires a tap check on the phone;
a successful build or app installation does not validate that OS handoff.

Dictate → App opening diagnostics → Recent activity shows the last 40 events:
process starts, Xcode-test starts, foreground/background transitions, shortcut
invocations, and known URL routes. Keyboard and Live Activity links carry distinct
source tags. These tags describe our link routes; iOS does not provide the actual
calling app for every activation. A foreground transition alone is not evidence
of a particular cause.

The log stores timestamps and fixed event labels in the app's preferences and
OS log. It does not record raw URLs, audio filenames, transcript text, or secrets.
It does not open or activate the app. Diagnosis of any recurrence should correlate
these events with whether a device test, shortcut, or Live Activity tap occurred.

2026-09-07 keyboard repair: More now expands inline and access help updates the
status label; no keyboard control presents a UIAlertController. Open Saywick is a
hosted SwiftUI user-tap URL action with an explicit rejected-request message.
Compact-layout and inline-action simulator regressions pass. Two attempts at the
physical handoff test failed before any test action because Xcode timed out enabling
automation mode. The signed build was installed; actual cross-app handoff remains
unverified on this phone.
