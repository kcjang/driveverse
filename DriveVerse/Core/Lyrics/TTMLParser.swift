import Foundation

/// Parser for the TTML that Apple Music's catalog returns for lyrics.
///
/// Output is the same `[LRCLine]` the rest of the pipeline already speaks, so
/// SyncEngine, the lyrics screen and the Live Activity need no changes —
/// only the source of the lines differs. Pure and I/O-free, like LRCParser.
///
/// Shape of the documents (`itunes:timing` is `Line`, `Word` or `None`):
/// ```xml
/// <tt xmlns="http://www.w3.org/ns/ttml" itunes:timing="Word">
///   <body>
///     <div>
///       <p begin="00:00:27.460" end="00:00:31.200">
///         <span begin="27.46s" end="27.90s">Life</span>
///         <span begin="27.90s" end="28.30s">is</span>
///         <span ttm:role="x-bg"><span begin="28.4s" end="29s">ooh</span></span>
///       </p>
/// ```
/// A word-timed line is still rendered a line at a time here: the `<p>` is
/// the unit the driver reads, and per-syllable updates would thrash the Live
/// Activity. The span timings are deliberately collapsed — keeping them would
/// mean a richer ContentState, which §5 of CLAUDE.md wants kept tiny.
enum TTMLParser {
    /// Time-ordered lyric lines, one per `<p>`. Empty when the document
    /// carries no timings at all (`itunes:timing="None"`), which is the
    /// caller's cue to fall back to `plainText`.
    static func parse(_ raw: String) -> [LRCLine] {
        collect(raw)
            .compactMap { entry in
                entry.timeMs.map { LRCLine(timeMs: $0, text: entry.text) }
            }
            .sorted { $0.timeMs < $1.timeMs }
    }

    /// Every line's text in document order, for documents with no timings.
    static func plainText(_ raw: String) -> String {
        collect(raw).map(\.text).joined(separator: "\n")
    }

    /// Parses a TTML time expression to milliseconds.
    ///
    /// Apple mixes forms even inside one document — `<p>` tends to carry
    /// `HH:MM:SS.mmm` while spans carry offset seconds like `27.46s`.
    /// Accepts `HH:MM:SS.mmm`, `MM:SS.mmm`, `SS.mmms` and a bare number of
    /// seconds; returns nil for anything else (including TTML's tick and
    /// frame forms, which Apple does not use for lyrics).
    static func timeMs(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if text.hasSuffix("s"), !text.hasSuffix("ms") {
            text.removeLast()
            guard let seconds = Double(text) else { return nil }
            return Int((seconds * 1000).rounded())
        }
        if text.hasSuffix("ms") {
            text.removeLast(2)
            return Double(text).map { Int($0.rounded()) }
        }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return Double(parts[0]).map { Int(($0 * 1000).rounded()) }
        case 2, 3:
            // Seconds may be fractional; hours and minutes are whole.
            guard let seconds = Double(parts[parts.count - 1]),
                  let minutes = Int(parts[parts.count - 2]) else { return nil }
            var total = Double(minutes * 60) + seconds
            if parts.count == 3 {
                guard let hours = Int(parts[0]) else { return nil }
                total += Double(hours * 3600)
            }
            return Int((total * 1000).rounded())
        default:
            return nil
        }
    }

    // MARK: - Internals

    private struct Entry {
        let timeMs: Int?
        let text: String
    }

    private static func collect(_ raw: String) -> [Entry] {
        guard let data = raw.data(using: .utf8) else { return [] }
        let collector = LineCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        // Lyrics carry ttm:/itunes: prefixes; without this the delegate sees
        // mangled element names for anything namespaced.
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return [] }
        return collector.entries
    }

    /// SAX collector: one Entry per `<p>`, text accumulated from every
    /// descendant so word spans and background-vocal spans both land in the
    /// line. Whitespace between spans is real content in TTML, so it is kept
    /// and only collapsed at the end.
    private final class LineCollector: NSObject, XMLParserDelegate {
        var entries: [Entry] = []

        private var depth = 0
        private var beginAttr: String?
        private var firstSpanBegin: String?
        private var buffer = ""

        /// Reported names vary with namespace handling and with how a
        /// document declares its prefixes, so match on the local part.
        private func isLine(_ elementName: String) -> Bool {
            elementName.split(separator: ":").last == "p"
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            if isLine(elementName) {
                depth = 1
                beginAttr = attributeDict["begin"]
                firstSpanBegin = nil
                buffer = ""
            } else if depth > 0 {
                depth += 1
                // A line whose own begin is missing can still be placed from
                // its first timed span.
                if firstSpanBegin == nil, let begin = attributeDict["begin"] {
                    firstSpanBegin = begin
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard depth > 0 else { return }
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard depth > 0 else { return }
            if isLine(elementName) {
                depth = 0
                let text = buffer
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                if !text.isEmpty {
                    entries.append(Entry(timeMs: (beginAttr ?? firstSpanBegin).flatMap(timeMs), text: text))
                }
                buffer = ""
                beginAttr = nil
                firstSpanBegin = nil
            } else {
                depth -= 1
            }
        }
    }
}
