import Foundation
import VoiceKeyboardCore

let startedAt = Date(timeIntervalSince1970: 100)
var accumulator = TranscriptAccumulator(startedAt: startedAt)
accumulator.consume(.partial(text: "hello", receivedAt: startedAt.addingTimeInterval(0.2)))
accumulator.consume(
    .final(
        text: "hello world",
        endOfUtteranceLatencyMilliseconds: 250,
        receivedAt: startedAt.addingTimeInterval(0.8)
    )
)

precondition(accumulator.finalizedText == "hello world")
precondition(accumulator.partialText.isEmpty)
precondition(abs((accumulator.metrics.firstPartialMilliseconds ?? 0) - 200) < 0.001)
precondition(abs((accumulator.metrics.firstFinalMilliseconds ?? 0) - 800) < 0.001)
precondition(accumulator.metrics.latestEndOfUtteranceMilliseconds == 250)
precondition(RuleBasedCleaner.clean("  hello   world  ") == "Hello world.")

let snapshot = SharedSessionSnapshot(
    phase: .ready,
    finalizedText: "hello world",
    processedText: "Hello world."
)
precondition(snapshot.insertableText == "Hello world.")
precondition(TranscriptOutputSanitizer.clean("<transcript>Hello world.</transcript>") == "Hello world.")
precondition(
    SpokenVoiceCommandParser.match(in: "hello there stop and insert")
        == SpokenVoiceCommandMatch(command: .stopAndInsert, transcriptBeforeCommand: "hello there")
)

print("Core smoke checks passed")
