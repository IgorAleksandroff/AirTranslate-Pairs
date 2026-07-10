import Foundation
import Testing
@testable import AirTranslate

@Suite
struct OpenAITranslationStreamParserTests {
    @Test
    func accumulatesOutputTextDeltas() {
        var parser = OpenAITranslationStreamParser()
        let first = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"안녕"}"#)
        let second = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"하세요"}"#)
        #expect(first == "안녕")
        #expect(second == "안녕하세요")
        #expect(parser.finalText == "안녕하세요")
    }

    @Test
    func parsesDataLineWithoutSpaceAfterPrefix() {
        var parser = OpenAITranslationStreamParser()
        let partial = parser.consume(line: #"data:{"type":"response.output_text.delta","delta":"Hello"}"#)
        #expect(partial == "Hello")
    }

    @Test
    func ignoresNonDataAndMalformedLines() {
        var parser = OpenAITranslationStreamParser()
        #expect(parser.consume(line: "event: response.output_text.delta") == nil)
        #expect(parser.consume(line: "") == nil)
        #expect(parser.consume(line: ": keep-alive") == nil)
        #expect(parser.consume(line: "data: not-json") == nil)
        #expect(parser.consume(line: #"data: {"delta":"missing type"}"#) == nil)
        #expect(!parser.didEncounterFailureEvent)
        #expect(parser.finalText == nil)
    }

    @Test
    func prefersCompletedResponseTextOverDoneAndDeltas() {
        var parser = OpenAITranslationStreamParser()
        _ = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"partial"}"#)
        _ = parser.consume(line: #"data: {"type":"response.output_text.done","text":"done text"}"#)
        _ = parser.consume(
            line: #"data: {"type":"response.completed","response":{"output":[{"content":[{"text":"completed text"}]}]}}"#
        )
        #expect(parser.finalText == "completed text")
    }

    @Test
    func fallsBackToDoneTextWhenCompletedEventIsMissing() {
        var parser = OpenAITranslationStreamParser()
        _ = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"partial"}"#)
        _ = parser.consume(line: #"data: {"type":"response.output_text.done","text":"done text"}"#)
        #expect(parser.finalText == "done text")
    }

    @Test
    func fallsBackToAccumulatedDeltasWhenTerminalEventsAreMissing() {
        var parser = OpenAITranslationStreamParser()
        _ = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"only "}"#)
        _ = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"deltas"}"#)
        #expect(parser.finalText == "only deltas")
    }

    @Test
    func failureEventInvalidatesStreamedText() {
        var parser = OpenAITranslationStreamParser()
        _ = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"partial"}"#)
        _ = parser.consume(line: #"data: {"type":"response.failed"}"#)
        #expect(parser.didEncounterFailureEvent)
        #expect(parser.finalText == nil)
    }

    @Test
    func errorAndIncompleteEventsInvalidateStreamedText() {
        for failureType in ["error", "response.incomplete"] {
            var parser = OpenAITranslationStreamParser()
            _ = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"partial"}"#)
            _ = parser.consume(line: "data: {\"type\":\"\(failureType)\"}")
            #expect(parser.didEncounterFailureEvent)
            #expect(parser.finalText == nil)
        }
    }

    @Test
    func whitespaceOnlyStreamYieldsNoFinalText() {
        var parser = OpenAITranslationStreamParser()
        _ = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"  "}"#)
        #expect(parser.finalText == nil)
    }

    @Test
    func emptyStreamYieldsNoFinalText() {
        let parser = OpenAITranslationStreamParser()
        #expect(parser.finalText == nil)
    }
}
