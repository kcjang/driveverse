import Foundation

/// Cache-first lyrics lookup: signature → cache → LRCLIB → cache.
final class LyricsService {
    private let client: LRCLIBClient
    private let cache: LyricsCache

    init(client: LRCLIBClient = LRCLIBClient(), cache: LyricsCache = LyricsCache()) {
        self.client = client
        self.cache = cache
    }

    func lyrics(for state: NowPlayingState) async throws -> LyricsFetchResult {
        // Reads probe the neighbouring duration buckets too, so a track whose
        // reported length straddles a bucket boundary still hits; the write
        // below goes to the primary key only.
        let candidates = LyricsMatcher.cacheSignatures(
            title: state.title, artist: state.artist, durationMs: state.durationMs
        )
        for candidate in candidates {
            if let hit = cache.lookup(signature: candidate) {
                return hit
            }
        }
        let result = try await client.fetchLyrics(
            title: state.title, artist: state.artist,
            album: state.album, durationMs: state.durationMs
        )
        cache.store(result, signature: LyricsMatcher.signature(
            title: state.title, artist: state.artist, durationMs: state.durationMs
        ))
        return result
    }

    /// Once-per-launch disk housekeeping; see LyricsCache.prune().
    func pruneCache() {
        cache.prune()
    }

    func clearCache() {
        cache.clear()
    }
}
