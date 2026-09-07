# Saywick and Spokenly — 2026-09-07

This is a comparison of our source and Spokenly's published documentation, not a
head-to-head device benchmark. Their exact model weights and idle timeout have not
been verified.

| Area | Saywick after simplification | Spokenly's published behavior |
| --- | --- | --- |
| Recognition | Parakeet Unified English Q8_0, local CPU + Accelerate | Free local Parakeet, plus other local and cloud choices |
| Keyboard | Basic English QWERTY, Shift, numbers/punctuation, separate voice panel | Classic and voice layouts, multilingual layouts and emoji |
| Activation | Shortcut opens app for cold activation; dictation restarts in background while ready | Background Dictation Shortcut claims activation without switching apps |
| Idle microphone | Stops after 120 seconds between finished dictations; active recording is uncapped | Default/available idle timeout not established from primary documentation |
| Full Access | Typing works without it; dictation bridge requires it | Background Dictation instructions require it for keyboard insertion |
| OS | iOS 26 | App Store lists iOS 16.4; background shortcut documentation requires iOS 17 |
| Scope | Local dictation, faithful cleanup, custom corrections, retained history/audio | Broader model selection, modes and cross-platform product |

Sources:
- [Spokenly iPhone overview](https://spokenly.app/dictation-for-iphone): local Parakeet and free local dictation. Its claim that local keyboard use needs no Full Access conflicts with the setup instructions; do not treat it as verified.
- [Background Dictation documentation](https://spokenly.app/docs/ios/background-dictation): Action Button/Back Tap/AssistiveTouch, direct keyboard insertion or clipboard, no foreground switch, Live Activities required. This informed the recording intents in Saywick. Cold microphone activation still required foreground continuation on the test iPhone.
- [App Store listing](https://apps.apple.com/us/app/spokenly-audio-to-text-ai-app/id6740315592): compatibility and release notes describing classic/voice keyboards, multilingual layouts, emoji and smart text handling.

Spokenly markets Neural Engine acceleration, whereas our measured runtime uses
CPU + Accelerate. Without the same recordings, device, and runtime/model settings,
we cannot conclude equal accuracy, latency, battery use, or memory consumption.
Local Parakeet alone is already available free in a competitor. Saywick's potential
appeal is its simpler configuration and control over faithful text and local history;
that is a product judgment, not evidence that it outperforms Spokenly.
