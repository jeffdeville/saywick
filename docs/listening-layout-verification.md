# Keyboard layout and signing verification

Typing mode uses an iOS-style US QWERTY layout: staggered rows, consistent key
sizes, Shift and Delete beside the third row, number and symbol pages, a wide
space bar, Return, and globe/microphone controls. Key colors adapt to light and
dark appearance. This is a custom UIKit implementation, not Apple's private
keyboard, and does not provide its predictive text or autocorrection engine.

Listening dedicates the available height to its scrollable transcript and
Cancel/Stop row. Heading, status instructions, More, and typing keys are hidden.
Stop includes a pulsing waveform; Reduce Motion uses a static icon. Incoming
transcript changes follow the newest text; unchanged polling preserves manual
scrolling. The app transcript also scrolls within its compact viewport.

Passing source coverage: `.build/Coverage/run-20260911-190937/`.
Coverage is 76.95% overall and 84.88% for refactored code. Production source
fingerprints match the report. Thirteen physical-device unit tests pass in
`.build/Coverage/native-typing-phone.xcresult`, including missing-ID insertion,
Undo safety, scrolling, compact listening controls, and typing fallback.
Light rendering at 320 points and dark rendering at 393 points were inspected.
The corrected dark fixture hosts the keyboard in a real UIKit window and passes
in `.build/Coverage/native-typing-dark-window.xcresult`.

The physical keyboard-opening UI test could not initialize because Xcode timed
out enabling automation mode. It is not counted as passing. The user explicitly
requested installation despite that infrastructure limitation.

Paid developer team A53ZJT2BBL matches the stabilizer's Signing.xcconfig. All four
production profiles (app, keyboard, Share, Live Activity) expire September 11,
2027. The signature-verified Release and matching symbols are preserved at
`.local-diagnostics/builds/addffdd0732827dcdbbd/`.
The Release was installed on Jeff's iPhone and successfully launched at
19:15 EDT on September 11, 2026. Local provenance and diagnostic triage records
contain the installation evidence and symbol UUIDs for subsequent crash checks.

## Footer and recording icon update — September 11, 2026

Removed the duplicated globe/microphone footer, reducing typing height from 258
to 210 points. A lips icon beside 123 retains access to Saywick dictation. The
listening button uses twelve animated blue rounded bars based on the supplied
reference, with a static frame for Reduce Motion. Animation stops on dismissal.

Coverage run `run-20260911-193344` passes at 77.66% overall and 86.59% for the
refactor. All 13 phone regressions pass in `lips-keyboard-phone.xcresult`.
Phone-rendered light and dark layouts were visually inspected. Signed Release
and matching symbols are preserved in `.local-diagnostics/builds/ff34025cc52a9d66a602`;
this update was installed at 19:35 EDT. Physical keyboard-opening UI automation
remains subject to the previously documented infrastructure limitation.
