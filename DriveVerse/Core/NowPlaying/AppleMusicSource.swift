import Foundation
import Combine

enum MediaAuthStatus: Equatable {
    case unknown
    case authorized
    case denied
}

/// Plain snapshot of MPMusicPlayerController state — lets the mapping be pure
/// and unit-testable with fakes (MediaPlayer itself needs a real device).
struct AppleMusicSnapshot: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var durationSec: Double
    var positionSec: Double
    var isPlaying: Bool
}

enum AppleMusicStateMapper {
    /// `previous` is the last state this source emitted, used only to survive
    /// an unreadable position — see below.
    static func state(
        from snapshot: AppleMusicSnapshot?,
        capturedAt: Date,
        previous: NowPlayingState? = nil
    ) -> NowPlayingState? {
        guard let snapshot, let title = snapshot.title, !title.isEmpty else { return nil }
        let artist = snapshot.artist ?? ""
        let durationMs = (snapshot.durationSec.isFinite && snapshot.durationSec > 0)
            ? Int(snapshot.durationSec * 1000) : nil

        // MediaPlayer hands out a NaN currentPlaybackTime while the player is
        // in an indeterminate state. Reading that as position 0 looks like a
        // seek to the top of the track, so the sync engine would snap the
        // lyrics back to the first line mid-song. Carry the previous anchor
        // forward instead — position *and* the time it was captured, so
        // extrapolation simply keeps running. With nothing to carry (first
        // report, or a different track) 0 is all we have.
        let carried = previous.flatMap {
            ($0.source == .appleMusic && $0.title == title && $0.artist == artist) ? $0 : nil
        }
        let anchor: (positionMs: Int, capturedAt: Date) = snapshot.positionSec.isFinite
            ? (max(0, Int(snapshot.positionSec * 1000)), capturedAt)
            : (carried?.positionMs ?? 0, carried?.capturedAt ?? capturedAt)

        return NowPlayingState(
            title: title,
            artist: artist,
            album: snapshot.album,
            durationMs: durationMs,
            positionMs: anchor.positionMs,
            isPlaying: snapshot.isPlaying,
            source: .appleMusic,
            capturedAt: anchor.capturedAt
        )
    }
}

#if os(iOS)
import MediaPlayer

/// Observes the system (Apple Music) player via the MediaPlayer framework.
/// Zero-latency and exact-position, so the coordinator prefers it when playing.
/// Emits nil when Apple Music has no now-playing item (e.g. Spotify is the
/// one playing). No MusicKit, no developer token — per CLAUDE.md §2.2.
final class AppleMusicSource: NowPlayingSource {
    private let player = MPMusicPlayerController.systemMusicPlayer
    private let subject = CurrentValueSubject<NowPlayingState?, Never>(nil)
    let authStatusSubject = CurrentValueSubject<MediaAuthStatus, Never>(.unknown)

    var statePublisher: AnyPublisher<NowPlayingState?, Never> { subject.eraseToAnyPublisher() }

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var started = false
    /// start() can finish without observing at all (authorization denied),
    /// so endGeneratingPlaybackNotifications must not be called unpaired.
    private var observing = false

    func start() {
        guard !started else { return }
        started = true
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            authStatusSubject.send(.authorized)
            beginObserving()
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if status == .authorized {
                        self.authStatusSubject.send(.authorized)
                        self.beginObserving()
                    } else {
                        self.authStatusSubject.send(.denied)
                        self.subject.send(nil)
                    }
                }
            }
        default:
            authStatusSubject.send(.denied)
            subject.send(nil)
        }
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        lastSnapshot = nil
        lastState = nil
        if observing {
            observing = false
            player.endGeneratingPlaybackNotifications()
        }
    }

    private func beginObserving() {
        observing = true
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name: Notification.Name in [
            .MPMusicPlayerControllerNowPlayingItemDidChange,
            .MPMusicPlayerControllerPlaybackStateDidChange,
        ] {
            observers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                self?.emit()
            })
        }
        // 1 s poll of the full player state — MediaPlayer notifications are
        // flaky while backgrounded (Drive Mode), so track switches and
        // pauses must also be caught by polling, not notifications alone.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.emit()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        emit()
    }

    /// Foreground resync: read the player immediately instead of waiting for
    /// the next tick or a notification that may never have arrived.
    func refresh() {
        guard timer != nil else { return }
        emit()
    }

    private var lastSnapshot: AppleMusicSnapshot??
    /// Last emitted state — the mapper reuses its anchor when the player
    /// reports an unreadable (NaN) position.
    private var lastState: NowPlayingState?

    private func emit() {
        let snapshot = player.nowPlayingItem.map { item in
            AppleMusicSnapshot(
                title: item.title,
                artist: item.artist,
                album: item.albumTitle,
                durationSec: item.playbackDuration,
                positionSec: player.currentPlaybackTime,
                isPlaying: player.playbackState == .playing
            )
        }
        // While playing the position advances every tick, so this always
        // sends; while paused or idle it collapses the 1 s tick to real
        // changes only, keeping the UI and sync pipeline quiet.
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        // A NaN position makes every snapshot compare unequal, so this path
        // repeats while the player is indeterminate; the carried-forward
        // anchor makes each state identical and the coordinator's
        // removeDuplicates() absorbs them.
        let state = AppleMusicStateMapper.state(from: snapshot, capturedAt: Date(), previous: lastState)
        lastState = state
        subject.send(state)
    }
}
#endif
