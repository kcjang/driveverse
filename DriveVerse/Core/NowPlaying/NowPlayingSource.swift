import Foundation
import Combine

enum MusicSource: String, Codable, Equatable, CaseIterable {
    case appleMusic
    case spotify

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }
}

struct NowPlayingState: Equatable {
    let title: String
    let artist: String
    let album: String?
    let durationMs: Int?
    let positionMs: Int
    let isPlaying: Bool
    let source: MusicSource
    /// When `positionMs` was observed — the sync engine extrapolates from here.
    let capturedAt: Date
    /// Apple Music catalog identifier, from MPMediaItem.playbackStoreID.
    /// Exact where title/artist matching only guesses, so a lyrics provider
    /// that speaks catalog IDs can skip the guessing entirely. Nil for
    /// Spotify and for library items with no store equivalent.
    let catalogID: String?

    init(
        title: String,
        artist: String,
        album: String?,
        durationMs: Int?,
        positionMs: Int,
        isPlaying: Bool,
        source: MusicSource,
        capturedAt: Date,
        catalogID: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.source = source
        self.capturedAt = capturedAt
        self.catalogID = catalogID
    }

    func with(isPlaying: Bool) -> NowPlayingState {
        NowPlayingState(
            title: title, artist: artist, album: album,
            durationMs: durationMs, positionMs: positionMs,
            isPlaying: isPlaying, source: source, capturedAt: capturedAt,
            catalogID: catalogID
        )
    }

    /// Same logical track (ignoring position/playback flags).
    func isSameTrack(as other: NowPlayingState) -> Bool {
        title == other.title && artist == other.artist && source == other.source
    }
}

protocol NowPlayingSource {
    var statePublisher: AnyPublisher<NowPlayingState?, Never> { get }
    func start()
    func stop()
}
