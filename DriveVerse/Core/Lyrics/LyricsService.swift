import Foundation
import os

/// Cache-first lyrics lookup across the available providers.
///
/// Order is Apple, then LRCLIB. Apple is asked only when the track carries a
/// catalog id and the user has connected, and *every* way it can fail —
/// thrown error, nothing found — falls through to LRCLIB rather than
/// surfacing. That is deliberate: the Apple path rides on an internal API
/// that can break without notice, and a driver should lose lyric quality,
/// never lyrics.
final class LyricsService {
    private static let log = Logger(subsystem: "com.kichang.driveverse", category: "lyrics")

    private let client: LRCLIBClient
    private let appleClient: AppleLyricsClient?
    private let appleCredentials: (any AppleMusicCredentialProviding)?
    private let cache: LyricsCache

    init(
        client: LRCLIBClient = LRCLIBClient(),
        appleClient: AppleLyricsClient? = nil,
        appleCredentials: (any AppleMusicCredentialProviding)? = nil,
        cache: LyricsCache = LyricsCache()
    ) {
        self.client = client
        self.appleClient = appleClient
        self.appleCredentials = appleCredentials
        self.cache = cache
    }

    /// Catalog ids are exact, so one is worth more than the title/artist
    /// signature and its duration bucket. Reads try it first.
    static func catalogKey(_ catalogID: String) -> String { "apple:\(catalogID)" }

    func lyrics(for state: NowPlayingState) async throws -> LyricsFetchResult {
        let catalogKey = state.catalogID.map(Self.catalogKey)
        let signatureKeys = LyricsMatcher.cacheSignatures(
            title: state.title, artist: state.artist, durationMs: state.durationMs
        )
        let appleAvailable = await canAskApple(for: state)

        for key in ([catalogKey].compactMap { $0 } + signatureKeys) {
            guard let hit = cache.lookup(signature: key) else { continue }
            // A miss is only as good as the providers that produced it.
            // Entries under a signature key predate Apple being available,
            // so they say nothing about what Apple would answer now —
            // without this, connecting Apple changes nothing for a day.
            if hit == .notFound, appleAvailable, key != catalogKey { continue }
            return hit
        }

        var result = await appleLyrics(for: state)
        if result == nil || result == .notFound {
            // LRCLIB may still have a track Apple does not, so a miss up
            // there is not the end of the chain.
            let fallback = try await client.fetchLyrics(
                title: state.title, artist: state.artist,
                album: state.album, durationMs: state.durationMs
            )
            if fallback != .notFound || result == nil {
                result = fallback
            }
        }

        let resolved = result ?? .notFound
        // Negatives recorded without Apple must not land on the catalog key,
        // or they would be trusted later once Apple is connected.
        let key = appleAvailable ? (catalogKey ?? signatureKeys[0]) : signatureKeys[0]
        cache.store(resolved, signature: key)
        return resolved
    }

    private func canAskApple(for state: NowPlayingState) async -> Bool {
        guard appleClient != nil, let credentials = appleCredentials, state.catalogID != nil else {
            return false
        }
        return await credentials.isConnected
    }

    /// nil means "Apple was not asked, or could not answer" — distinct from
    /// `.notFound`, which means Apple was asked and has nothing.
    private func appleLyrics(for state: NowPlayingState) async -> LyricsFetchResult? {
        guard let appleClient,
              let credentials = appleCredentials,
              let catalogID = state.catalogID,
              await credentials.isConnected else { return nil }
        do {
            return try await appleClient.lyrics(catalogID: catalogID)
        } catch {
            Self.log.warning("apple lyrics failed, falling back to LRCLIB: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Once-per-launch disk housekeeping; see LyricsCache.prune().
    func pruneCache() {
        cache.prune()
    }

    func clearCache() {
        cache.clear()
    }
}
