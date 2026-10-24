import Foundation
import CryptoKit

struct CachedLyrics: Codable, Equatable {
    let result: LyricsFetchResult
    let storedAt: Date
}

/// Disk cache for lyric lookups, keyed by track signature.
/// Per CLAUDE.md §2.5: local-only, entries never served past 30 days.
/// Negative results (`notFound`) are retried after a day.
final class LyricsCache {
    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let notFoundMaxAge: TimeInterval = 24 * 3600
    /// Ceiling for the sweep — a few hundred KB of JSON at typical sizes.
    static let maxEntries = 500

    private let directory: URL
    private let fileManager = FileManager.default
    var now: () -> Date

    init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricsCache", isDirectory: true)
        self.now = now
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func lookup(signature: String) -> LyricsFetchResult? {
        let url = fileURL(for: signature)
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedLyrics.self, from: data) else {
            return nil
        }
        let age = now().timeIntervalSince(cached.storedAt)
        let limit = cached.result == .notFound ? Self.notFoundMaxAge : Self.maxAge
        guard age >= 0, age < limit else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return cached.result
    }

    func store(_ result: LyricsFetchResult, signature: String) {
        let cached = CachedLyrics(result: result, storedAt: now())
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: fileURL(for: signature), options: .atomic)
    }

    /// Housekeeping sweep, run once per launch.
    ///
    /// `lookup` only discards an entry when something asks for it, so a track
    /// never played again would sit on disk forever. This drops anything past
    /// `maxAge` and then trims the oldest until at most `maxEntries` remain.
    /// It works off file modification dates rather than the stored timestamps
    /// so it costs one directory enumeration instead of decoding every file —
    /// `lookup` remains the authority on freshness, including the shorter
    /// not-found TTL. Bounding disk use is all this has to get right.
    func prune() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let cutoff = now().addingTimeInterval(-Self.maxAge)
        var living: [(url: URL, modified: Date)] = []
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            } else {
                living.append((url, modified))
            }
        }

        guard living.count > Self.maxEntries else { return }
        let doomed = living.sorted { $0.modified < $1.modified }
            .prefix(living.count - Self.maxEntries)
        for entry in doomed {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    func clear() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for signature: String) -> URL {
        let digest = SHA256.hash(data: Data(signature.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
}
