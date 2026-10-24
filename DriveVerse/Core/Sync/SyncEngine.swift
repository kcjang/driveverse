import Foundation
import Combine

struct LyricsPosition: Equatable {
    let positionMs: Int
    let lineIndex: Int?
    let currentLine: String?
    let nextLine: String?
    /// 0–1 through the current line's time window.
    let lineProgress: Double
    /// 0–1 through the whole track.
    let trackProgress: Double
    let isPlaying: Bool
}

/// Extrapolates playback position between source reports (Spotify only polls
/// every ~5 s) and maps the position to the current LRC line index.
/// The clock is injected so every code path is unit-testable.
final class SyncEngine {
    /// Spotify is polled every 3–10 s and the position is extrapolated in
    /// between, so deviations of a second or two are polling jitter rather
    /// than movement and adopting them makes the display stutter.
    static let spotifySeekThresholdMs = 2000
    /// Apple Music hands back an exact position every second, so there is no
    /// jitter to absorb. The old shared 2 s grace meant a lag of up to two
    /// seconds was treated as noise and never corrected — with lyric lines
    /// often 2–4 s apart, that alone could hold the wrong line on screen.
    static let appleMusicSeekThresholdMs = 500
    static let tickInterval: TimeInterval = 0.5

    static func seekThresholdMs(for source: MusicSource) -> Int {
        switch source {
        case .appleMusic: return appleMusicSeekThresholdMs
        case .spotify: return spotifySeekThresholdMs
        }
    }

    /// User nudge for LRC files whose timings are off, in milliseconds.
    /// Positive delays the lyrics (each line shows later). Applies to the
    /// line lookup only — the progress bar keeps showing true playback.
    var lyricOffsetMs = 0

    var now: () -> Date
    private(set) var anchor: NowPlayingState?
    private(set) var lines: [LRCLine] = []
    let positionSubject = CurrentValueSubject<LyricsPosition?, Never>(nil)
    private var timer: AnyCancellable?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func setLyrics(_ lines: [LRCLine]) {
        self.lines = lines
        tick()
    }

    /// Adopts a new source report. Small deviations from the extrapolated
    /// position (≤ 2 s) are treated as polling jitter and ignored so the
    /// display doesn't stutter; anything larger is a seek and snaps.
    func apply(_ state: NowPlayingState?) {
        defer { tick() }
        guard let new = state else {
            anchor = nil
            return
        }
        if let current = anchor,
           current.isSameTrack(as: new),
           current.isPlaying == new.isPlaying,
           new.isPlaying {
            let expected = Self.extrapolatedPositionMs(anchor: current, at: new.capturedAt)
            if abs(expected - new.positionMs) <= Self.seekThresholdMs(for: new.source) {
                return // within jitter tolerance — keep the smoother existing anchor
            }
        }
        anchor = new // new track, play/pause flip, or a real seek: snap
    }

    func startTicking() {
        timer = Timer.publish(every: Self.tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func stopTicking() {
        timer = nil
    }

    func tick() {
        guard let anchor else {
            positionSubject.send(nil)
            return
        }
        let pos = Self.extrapolatedPositionMs(anchor: anchor, at: now())
        positionSubject.send(Self.position(
            atMs: pos, lines: lines,
            durationMs: anchor.durationMs, isPlaying: anchor.isPlaying,
            lyricOffsetMs: lyricOffsetMs
        ))
    }

    // MARK: - Pure helpers

    static func extrapolatedPositionMs(anchor: NowPlayingState, at date: Date) -> Int {
        guard anchor.isPlaying else { return anchor.positionMs }
        let elapsedMs = Int((date.timeIntervalSince(anchor.capturedAt) * 1000).rounded())
        let pos = max(0, anchor.positionMs + elapsedMs)
        if let duration = anchor.durationMs {
            return min(pos, duration)
        }
        return pos
    }

    /// Index of the last line with timestamp ≤ position (binary search);
    /// nil before the first line or when there are no lines.
    static func lineIndex(forPositionMs pos: Int, in lines: [LRCLine]) -> Int? {
        guard let first = lines.first, pos >= first.timeMs else { return nil }
        var lo = 0
        var hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].timeMs <= pos {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    static func position(
        atMs pos: Int,
        lines: [LRCLine],
        durationMs: Int?,
        isPlaying: Bool,
        lyricOffsetMs: Int = 0
    ) -> LyricsPosition {
        // Only the lyric lookup is nudged; positionMs and trackProgress stay
        // true playback so the progress bar never lies.
        let lyricPos = pos - lyricOffsetMs
        let index = lineIndex(forPositionMs: lyricPos, in: lines)
        let currentLine = index.map { lines[$0].text }
        let nextLine: String?
        if let index {
            nextLine = index + 1 < lines.count ? lines[index + 1].text : nil
        } else {
            nextLine = lines.first?.text
        }

        var lineProgress = 0.0
        if let index {
            let start = lines[index].timeMs
            let end = index + 1 < lines.count ? lines[index + 1].timeMs : (durationMs ?? start + 5000)
            if end > start {
                lineProgress = min(1, max(0, Double(lyricPos - start) / Double(end - start)))
            }
        }
        let trackProgress = durationMs.flatMap { dur in
            dur > 0 ? min(1, max(0, Double(pos) / Double(dur))) : nil
        } ?? 0

        return LyricsPosition(
            positionMs: pos, lineIndex: index,
            currentLine: currentLine, nextLine: nextLine,
            lineProgress: lineProgress, trackProgress: trackProgress,
            isPlaying: isPlaying
        )
    }
}
