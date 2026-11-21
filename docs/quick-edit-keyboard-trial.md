# Quick edits between dictations

Revision 1, November 21, 2026. Requirements for a bounded feasibility trial against build 7 (e3414df). The owner chose to try improving short edits before deciding whether to retain QWERTY. That decision remains open.

## What the trial must deliver

Someone who usually dictates can fix a name or type a few words in the destination field, then resume dictating with Saywick. At normal typing speed, intended letters should appear once, in order, at the cursor. The person should be able to capitalize a name, delete a mistake, and insert a space. Starting the next dictation should preserve the manual edit. Keep the existing switch to other keyboards available for longer writing and preserve basic typing without Full Access.

Apple keyboard feature parity, prediction, swipe typing, and sustained composition are outside this trial. Touch handling and key layout details are delegated. The owner has not chosen to remove QWERTY or committed to keeping it.

## How to make the decision

On the owner’s iPhone, dictate into a text field. Correct a name in the middle, then dictate again. Repeat with a short phrase containing a space and repeated letters. Check what appeared, whether the correction survived, and whether any intended taps required a second attempt. Compare the effort with switching to Apple’s keyboard to make the same edits and switching back.

Keep QWERTY if the owner can make these edits reliably and prefers staying in Saywick. If missed or incorrect letters persist, or switching is easier, revisit the reduced editing row and dictation-only alternatives with the owner before committing further effort. No numerical error threshold has been agreed.

## Evidence and handoff

The owner experienced missed letters on the phone. In build 7, the keyboard uses individual buttons with six-point horizontal and ten-point vertical spacing. An accepted character action inserts through the host text proxy. The existing typing tests exercise button actions and layout. They do not establish real-finger accuracy or typing speed.

A temporary UIKit hit-test probe at a 393-point simulator width reached a button at all 26 letter centers and at none of the 23 midpoints between adjacent letters in the same row. This demonstrates a repeatable dead area. Its contribution to the owner’s missed taps and the impact of any fix remain unmeasured.

Read this revision before planning the trial. The next stage is a bounded touch-reliability investigation and a phone comparison. General keyboard development and release are separate decisions. Consult the [keyboard controller](../Sources/KeyboardExtension/KeyboardViewController.swift), [typing tests](../Tests/SaywickAppTests/TypingFallbackTests.swift), [keyboard session guide](keyboard-session.md), and [device checks](device-testing.md). Update the user guide and relevant keyboard guidance if the eventual decision changes the shipping behavior.
