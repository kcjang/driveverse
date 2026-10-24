import Foundation

/// Title/artist normalization for querying LRCLIB and for cache keys.
enum LyricsMatcher {
    /// "Song (feat. X) - Remix" → "song"
    static func normalizeTitle(_ raw: String) -> String {
        var s = raw.lowercased()
        s = stripBracketed(s)
        if let dash = s.range(of: " - ") {
            s = String(s[..<dash.lowerBound])
        }
        s = stripFeatClause(s)
        return collapseWhitespace(s)
    }

    /// "Rihanna feat. JAY-Z" → "rihanna"
    static func normalizeArtist(_ raw: String) -> String {
        var s = raw.lowercased()
        s = stripBracketed(s)
        s = stripFeatClause(s)
        return collapseWhitespace(s)
    }

    /// Albums keep their subtitles: "Help! - Remastered" is a different
    /// record from "Help!", so the " - " and feat. trimming that helps track
    /// titles would merge distinct releases here. Only case and bracketed
    /// editions are normalized away.
    static func normalizeAlbum(_ raw: String) -> String {
        collapseWhitespace(stripBracketed(raw.lowercased()))
    }

    /// Cache key for a track. Duration is bucketed to 5 s so slightly different
    /// reports of the same track (Apple Music vs Spotify) usually collide.
    static func signature(title: String, artist: String, durationMs: Int?) -> String {
        key(title: title, artist: artist, bucket: durationMs.map(durationBucket) ?? -1)
    }

    /// Keys to probe on a cache *read*: the track's own bucket plus its
    /// neighbours. Bucketing has to put a boundary somewhere, and the two
    /// sources routinely report the same track a second or two apart — a
    /// track straddling a boundary would otherwise cost a redundant LRCLIB
    /// round trip every time playback switched source. Writes still go to
    /// the primary key alone, so neighbours are read-only aliases.
    static func cacheSignatures(title: String, artist: String, durationMs: Int?) -> [String] {
        guard let durationMs else {
            return [signature(title: title, artist: artist, durationMs: nil)]
        }
        let bucket = durationBucket(durationMs)
        // Bucket -1 is the "duration unknown" key; never alias onto it.
        return [bucket, bucket - 1, bucket + 1]
            .filter { $0 >= 0 }
            .map { key(title: title, artist: artist, bucket: $0) }
    }

    private static func durationBucket(_ durationMs: Int) -> Int {
        Int((Double(durationMs) / 5000.0).rounded())
    }

    private static func key(title: String, artist: String, bucket: Int) -> String {
        "\(normalizeTitle(title))|\(normalizeArtist(artist))|\(bucket)"
    }

    /// Picks the `/api/search` result that best describes the playing track:
    /// normalized title must match and the duration must be within ±3 s (when
    /// we know ours).
    ///
    /// LRCLIB is community-uploaded, so one song routinely has a dozen
    /// records and uploads of the same recording can differ by seconds —
    /// "Dynamite" carries both a 00:27.46 and a 00:29.83 timing for the same
    /// line. Taking the first synced hit therefore picked a timing at random.
    /// Rank instead: synced beats plain, then an exact artist match, then an
    /// album match, then the closest duration. Records that tie on all four
    /// are genuinely indistinguishable from their metadata — that residue is
    /// what the Settings lyric offset is for.
    static func bestMatch(
        from candidates: [LRCLIBResponse],
        title: String,
        artist: String? = nil,
        album: String? = nil,
        durationMs: Int?
    ) -> LRCLIBResponse? {
        let wantedTitle = normalizeTitle(title)
        let wantedArtist = artist.map(normalizeArtist)
        let wantedAlbum = album.map(normalizeAlbum)

        let matches = candidates.filter { candidate in
            guard normalizeTitle(candidate.trackName ?? "") == wantedTitle else { return false }
            guard let durationMs else { return true }
            guard let duration = candidate.duration else { return false }
            return abs(duration * 1000 - Double(durationMs)) <= 3000
        }

        // Lower is better in every slot, so plain tuple ordering ranks them.
        func rank(_ c: LRCLIBResponse) -> (Int, Int, Int, Double) {
            let unsynced = (c.syncedLyrics?.isEmpty == false) ? 0 : 1
            let artistMiss = wantedArtist.map { normalizeArtist(c.artistName ?? "") == $0 ? 0 : 1 } ?? 0
            let albumMiss = wantedAlbum.map { normalizeAlbum(c.albumName ?? "") == $0 ? 0 : 1 } ?? 0
            let durationGap = durationMs.flatMap { want in
                c.duration.map { abs($0 * 1000 - Double(want)) }
            } ?? 0
            return (unsynced, artistMiss, albumMiss, durationGap)
        }

        return matches.min { rank($0) < rank($1) }
    }

    // MARK: - Helpers

    /// Removes every `(…)` and `[…]` segment.
    private static func stripBracketed(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            if ch == "(" || ch == "[" {
                depth += 1
            } else if ch == ")" || ch == "]" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                out.append(ch)
            }
        }
        return out
    }

    private static let featMarkers = [" feat. ", " feat ", " featuring ", " ft. ", " ft "]

    private static func stripFeatClause(_ s: String) -> String {
        var s = s
        for marker in featMarkers {
            if let r = s.range(of: marker) {
                s = String(s[..<r.lowerBound])
            }
        }
        return s
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
