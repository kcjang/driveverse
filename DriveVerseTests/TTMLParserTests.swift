import Testing
import Foundation
@testable import DriveVerse

@Suite struct TTMLTimeTests {
    @Test func offsetSecondsWithSuffix() {
        #expect(TTMLParser.timeMs("27.46s") == 27_460)
        #expect(TTMLParser.timeMs("0.05s") == 50)
        #expect(TTMLParser.timeMs("166.812s") == 166_812)
    }

    @Test func clockFormats() {
        #expect(TTMLParser.timeMs("00:00:12.000") == 12_000)
        #expect(TTMLParser.timeMs("00:01:23.456") == 83_456)
        #expect(TTMLParser.timeMs("1:23.456") == 83_456)
        #expect(TTMLParser.timeMs("01:02:03.5") == 3_723_500)
    }

    @Test func bareSecondsAndMilliseconds() {
        #expect(TTMLParser.timeMs("12") == 12_000)
        #expect(TTMLParser.timeMs("1500ms") == 1_500)
    }

    @Test func rejectsNonsense() {
        #expect(TTMLParser.timeMs("") == nil)
        #expect(TTMLParser.timeMs("abc") == nil)
        #expect(TTMLParser.timeMs("10:20:30:40") == nil)
        // TTML tick/frame forms exist in the spec but not in Apple's lyrics.
        #expect(TTMLParser.timeMs("100t") == nil)
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(TTMLParser.timeMs("  27.46s  ") == 27_460)
    }
}

@Suite struct TTMLParserTests {
    @Test func lineTimedDocument() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" itunes:timing="Line">
          <body><div>
            <p begin="00:00:27.460" end="00:00:31.200">Life is sweet as honey</p>
            <p begin="00:00:31.200" end="00:00:34.000">Disco overload</p>
          </div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml) == [
            LRCLine(timeMs: 27_460, text: "Life is sweet as honey"),
            LRCLine(timeMs: 31_200, text: "Disco overload"),
        ])
    }

    /// Word timing is collapsed to one line: the `<p>` is the unit a driver
    /// reads, and per-syllable updates would thrash the Live Activity.
    @Test func wordTimedSpansCollapseToTheLine() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" itunes:timing="Word">
          <body><div>
            <p begin="27.46s" end="31.2s">
              <span begin="27.46s" end="27.90s">Life</span>
              <span begin="27.90s" end="28.30s">is</span>
              <span begin="28.30s" end="28.90s">sweet</span>
            </p>
          </div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml) == [LRCLine(timeMs: 27_460, text: "Life is sweet")])
    }

    @Test func backgroundVocalsStayInTheLine() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word">
          <body><div>
            <p begin="10s" end="14s">
              <span begin="10s" end="11s">Shine</span>
              <span ttm:role="x-bg"><span begin="11s" end="12s">(ooh)</span></span>
            </p>
          </div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml) == [LRCLine(timeMs: 10_000, text: "Shine (ooh)")])
    }

    /// Apple mixes clock form on `<p>` with offset seconds on spans.
    @Test func mixedTimestampFormsInOneDocument() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" itunes:timing="Word">
          <body><div>
            <p begin="00:00:05.500"><span begin="5.5s">one</span></p>
            <p begin="12.25s">two</p>
          </div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml) == [
            LRCLine(timeMs: 5_500, text: "one"),
            LRCLine(timeMs: 12_250, text: "two"),
        ])
    }

    @Test func lineWithoutBeginFallsBackToItsFirstSpan() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div>
            <p><span begin="9.75s" end="10s">Anyway</span></p>
          </div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml) == [LRCLine(timeMs: 9_750, text: "Anyway")])
    }

    @Test func outOfOrderLinesAreSorted() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div>
            <p begin="30s">later</p>
            <p begin="10s">earlier</p>
          </div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml).map(\.text) == ["earlier", "later"])
    }

    @Test func untimedDocumentYieldsNoSyncedLines() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" itunes:timing="None">
          <body><div>
            <p>First line</p>
            <p>Second line</p>
          </div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml).isEmpty)
        #expect(TTMLParser.plainText(ttml) == "First line\nSecond line")
    }

    @Test func multipleDivSectionsAreFlattened() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body>
            <div begin="10s"><p begin="10s">verse</p></div>
            <div begin="40s"><p begin="40s">chorus</p></div>
          </body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml).map(\.text) == ["verse", "chorus"])
    }

    @Test func entitiesAreDecodedAndWhitespaceCollapsed() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div>
            <p begin="1s">   rock   &amp;   roll
            </p>
          </div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml) == [LRCLine(timeMs: 1_000, text: "rock & roll")])
    }

    @Test func headMetadataIsNotMistakenForLyrics() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <head><metadata>
            <ttm:agent type="person" xml:id="v1"/>
            <songwriter>Someone Else</songwriter>
          </metadata></head>
          <body><div><p begin="2s" ttm:agent="v1">real lyric</p></div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml) == [LRCLine(timeMs: 2_000, text: "real lyric")])
    }

    @Test func emptyLinesAreDropped() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div>
            <p begin="1s"></p>
            <p begin="2s">   </p>
            <p begin="3s">kept</p>
          </div></body>
        </tt>
        """
        #expect(TTMLParser.parse(ttml) == [LRCLine(timeMs: 3_000, text: "kept")])
    }

    @Test func malformedXMLYieldsNothingRatherThanCrashing() {
        #expect(TTMLParser.parse("<tt><body><div><p begin=").isEmpty)
        #expect(TTMLParser.parse("").isEmpty)
        #expect(TTMLParser.parse("not xml at all").isEmpty)
    }
}
