import Testing
import Foundation
@testable import DriveVerse

@Suite struct AppleMusicMapperTests {
    private let at = Date(timeIntervalSinceReferenceDate: 750_000_000)

    @Test func nilSnapshotMapsToNil() {
        // No now-playing item — e.g. Spotify is the app that's playing.
        #expect(AppleMusicStateMapper.state(from: nil, capturedAt: at) == nil)
    }

    @Test func missingTitleMapsToNil() {
        let snapshot = AppleMusicSnapshot(
            title: nil, artist: "A", album: nil,
            durationSec: 100, positionSec: 5, isPlaying: true
        )
        #expect(AppleMusicStateMapper.state(from: snapshot, capturedAt: at) == nil)
    }

    @Test func fullMapping() {
        let snapshot = AppleMusicSnapshot(
            title: "Karma Police", artist: "Radiohead", album: "OK Computer",
            durationSec: 261.5, positionSec: 42.25, isPlaying: true
        )
        let state = AppleMusicStateMapper.state(from: snapshot, capturedAt: at)
        #expect(state == NowPlayingState(
            title: "Karma Police", artist: "Radiohead", album: "OK Computer",
            durationMs: 261_500, positionMs: 42_250,
            isPlaying: true, source: .appleMusic, capturedAt: at
        ))
    }

    @Test func nanPositionBecomesZero() {
        let snapshot = AppleMusicSnapshot(
            title: "T", artist: "A", album: nil,
            durationSec: 100, positionSec: .nan, isPlaying: false
        )
        #expect(AppleMusicStateMapper.state(from: snapshot, capturedAt: at)?.positionMs == 0)
    }

    /// Regression: a NaN position used to map to 0 while isPlaying stayed
    /// true, which the sync engine read as a seek to the top of the track and
    /// snapped the lyrics back to the first line mid-song. The previous
    /// anchor — position *and* its capture time — must survive instead, so
    /// extrapolation carries on uninterrupted.
    @Test func nanPositionKeepsPreviousAnchorForSameTrack() {
        let previous = NowPlayingState(
            title: "T", artist: "A", album: nil,
            durationMs: 100_000, positionMs: 42_000,
            isPlaying: true, source: .appleMusic,
            capturedAt: at.addingTimeInterval(-7)
        )
        let snapshot = AppleMusicSnapshot(
            title: "T", artist: "A", album: nil,
            durationSec: 100, positionSec: .nan, isPlaying: true
        )
        let state = AppleMusicStateMapper.state(from: snapshot, capturedAt: at, previous: previous)
        #expect(state?.positionMs == 42_000)
        #expect(state?.capturedAt == at.addingTimeInterval(-7))

        // The sync engine must see no seek: extrapolating the carried anchor
        // lands exactly where the old one would have.
        let now = at
        let engine = SyncEngine(now: { now })
        engine.apply(previous)
        engine.apply(state)
        #expect(engine.anchor == previous)
    }

    @Test func nanPositionOnADifferentTrackStartsAtZero() {
        let previous = NowPlayingState(
            title: "Old", artist: "A", album: nil,
            durationMs: 100_000, positionMs: 42_000,
            isPlaying: true, source: .appleMusic, capturedAt: at.addingTimeInterval(-7)
        )
        let snapshot = AppleMusicSnapshot(
            title: "New", artist: "A", album: nil,
            durationSec: 100, positionSec: .nan, isPlaying: true
        )
        let state = AppleMusicStateMapper.state(from: snapshot, capturedAt: at, previous: previous)
        #expect(state?.positionMs == 0)
        #expect(state?.capturedAt == at)
    }

    @Test func catalogIDIsCarriedThrough() {
        let snapshot = AppleMusicSnapshot(
            title: "T", artist: "A", album: nil,
            durationSec: 100, positionSec: 1, isPlaying: true,
            catalogID: "1535780432"
        )
        #expect(AppleMusicStateMapper.state(from: snapshot, capturedAt: at)?.catalogID == "1535780432")
    }

    @Test func missingCatalogIDStaysNil() {
        let snapshot = AppleMusicSnapshot(
            title: "T", artist: "A", album: nil,
            durationSec: 100, positionSec: 1, isPlaying: true
        )
        #expect(AppleMusicStateMapper.state(from: snapshot, capturedAt: at)?.catalogID == nil)
    }

    /// The carry-forward path rebuilds the state, so it must not drop the ID.
    @Test func nanPositionCarryForwardKeepsCatalogID() {
        let previous = NowPlayingState(
            title: "T", artist: "A", album: nil,
            durationMs: 100_000, positionMs: 42_000,
            isPlaying: true, source: .appleMusic,
            capturedAt: at.addingTimeInterval(-7), catalogID: "123"
        )
        let snapshot = AppleMusicSnapshot(
            title: "T", artist: "A", album: nil,
            durationSec: 100, positionSec: .nan, isPlaying: true,
            catalogID: "123"
        )
        let state = AppleMusicStateMapper.state(from: snapshot, capturedAt: at, previous: previous)
        #expect(state?.catalogID == "123")
        #expect(state?.positionMs == 42_000)
    }

    @Test func readablePositionIgnoresPrevious() {
        let previous = NowPlayingState(
            title: "T", artist: "A", album: nil,
            durationMs: 100_000, positionMs: 42_000,
            isPlaying: true, source: .appleMusic, capturedAt: at.addingTimeInterval(-7)
        )
        let snapshot = AppleMusicSnapshot(
            title: "T", artist: "A", album: nil,
            durationSec: 100, positionSec: 3, isPlaying: true
        )
        let state = AppleMusicStateMapper.state(from: snapshot, capturedAt: at, previous: previous)
        #expect(state?.positionMs == 3_000)
        #expect(state?.capturedAt == at)
    }

    @Test func zeroDurationBecomesNil() {
        let snapshot = AppleMusicSnapshot(
            title: "T", artist: "A", album: nil,
            durationSec: 0, positionSec: 1, isPlaying: true
        )
        #expect(AppleMusicStateMapper.state(from: snapshot, capturedAt: at)?.durationMs == nil)
    }

    @Test func missingArtistBecomesEmpty() {
        let snapshot = AppleMusicSnapshot(
            title: "T", artist: nil, album: nil,
            durationSec: 100, positionSec: 1, isPlaying: true
        )
        #expect(AppleMusicStateMapper.state(from: snapshot, capturedAt: at)?.artist == "")
    }
}
