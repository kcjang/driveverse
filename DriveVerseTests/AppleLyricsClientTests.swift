import Testing
import Foundation
@testable import DriveVerse

private let sampleTTML = """
<tt xmlns="http://www.w3.org/ns/ttml" itunes:timing="Line">
  <body><div>
    <p begin="00:00:12.000">first line</p>
    <p begin="00:00:16.500">second line</p>
  </div></body>
</tt>
"""

private func catalogJSON(lyrics: String? = nil, syllable: String? = nil) -> Data {
    func relationship(_ ttml: String?) -> String {
        guard let ttml else { return #"{"data":[]}"# }
        let escaped = ttml
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"data":[{"attributes":{"ttml":"\#(escaped)"}}]}"#
    }
    return Data("""
    {"data":[{"id":"1757558454","type":"songs","relationships":{
      "lyrics":\(relationship(lyrics)),
      "syllable-lyrics":\(relationship(syllable))
    }}]}
    """.utf8)
}

@Suite struct AppleLyricsURLTests {
    @Test func buildsCatalogURLWithBothRelationships() throws {
        let url = try #require(AppleLyricsClient.url(
            catalogID: "1757558454", storefront: "kr", language: "ko"
        ))
        #expect(url.absoluteString.hasPrefix(
            "https://amp-api.music.apple.com/v1/catalog/kr/songs/1757558454?"
        ))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "include[songs]" }?.value == "lyrics,syllable-lyrics")
        #expect(items.first { $0.name == "l" }?.value == "ko")
    }

    /// The storefront is part of the path, so it cannot be defaulted away —
    /// the same id reads as "정국" on kr and "Jung Kook" on us.
    @Test func storefrontChangesThePath() throws {
        let us = try #require(AppleLyricsClient.url(catalogID: "1", storefront: "us", language: "en-US"))
        #expect(us.path == "/v1/catalog/us/songs/1")
    }
}

@Suite struct AppleLyricsResponseTests {
    @Test func lineTimedLyricsBecomeSyncedTTML() {
        #expect(AppleLyricsClient.result(fromCatalogJSON: catalogJSON(lyrics: sampleTTML))
                == .syncedTTML(sampleTTML))
    }

    @Test func fallsBackToSyllableLyricsWhenLineTimedIsAbsent() {
        #expect(AppleLyricsClient.result(fromCatalogJSON: catalogJSON(syllable: sampleTTML))
                == .syncedTTML(sampleTTML))
    }

    @Test func noLyricsRelationshipIsNotFound() {
        #expect(AppleLyricsClient.result(fromCatalogJSON: catalogJSON()) == .notFound)
    }

    /// An untimed document still has words worth showing.
    @Test func untimedDocumentBecomesPlain() {
        let untimed = """
        <tt xmlns="http://www.w3.org/ns/ttml" itunes:timing="None">
          <body><div><p>just words</p></div></body>
        </tt>
        """
        #expect(AppleLyricsClient.result(fromCatalogJSON: catalogJSON(lyrics: untimed))
                == .plain("just words"))
    }

    @Test func garbageIsNotFoundRatherThanACrash() {
        #expect(AppleLyricsClient.result(fromCatalogJSON: Data("not json".utf8)) == .notFound)
        #expect(AppleLyricsClient.result(fromCatalogJSON: Data(#"{"data":[]}"#.utf8)) == .notFound)
    }
}

@MainActor
private final class FakeAppleCredentials: AppleMusicCredentialProviding {
    var isConnected = true
    var context = AppleCatalogContext(
        headers: ["authorization": "Bearer dev", "media-user-token": "user"],
        storefront: "kr",
        language: "ko"
    )
    var throwOnContext: Error?
    private(set) var unauthorizedCalls = 0

    func catalogContext() async throws -> AppleCatalogContext {
        if let throwOnContext { throw throwOnContext }
        return context
    }

    func handleUnauthorized() async { unauthorizedCalls += 1 }
}

extension HTTPStubbedTests {
@Suite struct LyricsProviderChainTests {
    private func makeService(
        credentials: FakeAppleCredentials,
        dir: URL
    ) -> LyricsService {
        let session = StubURLProtocol.makeSession()
        return LyricsService(
            client: LRCLIBClient(session: session),
            appleClient: AppleLyricsClient(session: session, credentials: credentials),
            appleCredentials: credentials,
            cache: LyricsCache(directory: dir)
        )
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("driveverse-chain-\(UUID().uuidString)")
    }

    private func state(catalogID: String?) -> NowPlayingState {
        NowPlayingState(
            title: "Who", artist: "지민", album: "MUSE",
            durationMs: 171_000, positionMs: 0,
            isPlaying: true, source: .appleMusic, capturedAt: Date(),
            catalogID: catalogID
        )
    }

    /// Routes by host so one stub can serve both providers.
    private func route(apple: @escaping () -> (Int, Data), lrclib: @escaping () -> (Int, Data)) {
        StubURLProtocol.reset { request in
            (request.url?.host?.contains("apple") == true) ? apple() : lrclib()
        }
    }

    @MainActor @Test func appleAnswersAndLRCLIBIsNeverAsked() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        route(apple: { (200, catalogJSON(lyrics: sampleTTML)) },
              lrclib: { (200, Data(#"{"syncedLyrics":"[00:01.00]wrong"}"#.utf8)) })

        let service = makeService(credentials: FakeAppleCredentials(), dir: dir)
        let result = try await service.lyrics(for: state(catalogID: "1757558454"))

        #expect(result == .syncedTTML(sampleTTML))
        #expect(StubURLProtocol.requests.allSatisfy { $0.url?.host?.contains("apple") == true })
    }

    /// Apple having nothing is not the end of the chain — LRCLIB may still
    /// carry the track.
    @MainActor @Test func appleMissFallsThroughToLRCLIB() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        route(apple: { (200, catalogJSON()) },
              lrclib: { (200, Data(#"{"syncedLyrics":"[00:01.00]from lrclib"}"#.utf8)) })

        let service = makeService(credentials: FakeAppleCredentials(), dir: dir)
        let result = try await service.lyrics(for: state(catalogID: "1757558454"))

        #expect(result == .synced("[00:01.00]from lrclib"))
    }

    /// The whole point of the fallback: the internal API can break, and the
    /// driver must not lose lyrics when it does.
    @MainActor @Test func appleErrorFallsThroughToLRCLIB() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        route(apple: { (500, Data()) },
              lrclib: { (200, Data(#"{"syncedLyrics":"[00:01.00]from lrclib"}"#.utf8)) })

        let service = makeService(credentials: FakeAppleCredentials(), dir: dir)
        let result = try await service.lyrics(for: state(catalogID: "1757558454"))

        #expect(result == .synced("[00:01.00]from lrclib"))
    }

    @MainActor @Test func unauthorizedIsReportedThenFallsBack() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        route(apple: { (401, Data()) },
              lrclib: { (200, Data(#"{"syncedLyrics":"[00:01.00]from lrclib"}"#.utf8)) })

        let credentials = FakeAppleCredentials()
        let service = makeService(credentials: credentials, dir: dir)
        _ = try await service.lyrics(for: state(catalogID: "1757558454"))

        #expect(credentials.unauthorizedCalls == 1)
    }

    @MainActor @Test func disconnectedSkipsAppleEntirely() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        route(apple: { (200, catalogJSON(lyrics: sampleTTML)) },
              lrclib: { (200, Data(#"{"syncedLyrics":"[00:01.00]from lrclib"}"#.utf8)) })

        let credentials = FakeAppleCredentials()
        credentials.isConnected = false
        let service = makeService(credentials: credentials, dir: dir)
        _ = try await service.lyrics(for: state(catalogID: "1757558454"))

        #expect(StubURLProtocol.requests.allSatisfy { $0.url?.host?.contains("apple") == false })
    }

    @MainActor @Test func noCatalogIDSkipsAppleEntirely() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        route(apple: { (200, catalogJSON(lyrics: sampleTTML)) },
              lrclib: { (200, Data(#"{"syncedLyrics":"[00:01.00]from lrclib"}"#.utf8)) })

        let service = makeService(credentials: FakeAppleCredentials(), dir: dir)
        let result = try await service.lyrics(for: state(catalogID: nil))

        #expect(result == .synced("[00:01.00]from lrclib"))
        #expect(StubURLProtocol.requests.allSatisfy { $0.url?.host?.contains("apple") == false })
    }

    /// Regression: a miss cached before Apple was connected used to be
    /// served straight back, so connecting Apple changed nothing for a day.
    @MainActor @Test func aMissCachedWithoutAppleDoesNotBlockApple() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let playing = state(catalogID: "1637408854")

        // First play with Apple disconnected: nobody has it.
        route(apple: { (200, catalogJSON(lyrics: sampleTTML)) }, lrclib: { (404, Data()) })
        let offline = FakeAppleCredentials()
        offline.isConnected = false
        #expect(try await makeService(credentials: offline, dir: dir).lyrics(for: playing) == .notFound)

        // Connect Apple and play it again — the stale miss must not win.
        route(apple: { (200, catalogJSON(lyrics: sampleTTML)) }, lrclib: { (404, Data()) })
        let online = FakeAppleCredentials()
        let result = try await makeService(credentials: online, dir: dir).lyrics(for: playing)
        #expect(result == .syncedTTML(sampleTTML))
    }

    /// Once Apple has been asked, its miss is worth keeping for the day.
    @MainActor @Test func aMissRecordedWithAppleIsReused() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let playing = state(catalogID: "1637408854")

        route(apple: { (200, catalogJSON()) }, lrclib: { (404, Data()) })
        let credentials = FakeAppleCredentials()
        #expect(try await makeService(credentials: credentials, dir: dir).lyrics(for: playing) == .notFound)
        let afterFirst = StubURLProtocol.requests.count

        #expect(try await makeService(credentials: credentials, dir: dir).lyrics(for: playing) == .notFound)
        #expect(StubURLProtocol.requests.count == afterFirst)
    }

    /// The catalog id is exact, so it is the cache key when present — a
    /// second play must not go back to the network.
    @MainActor @Test func resultIsCachedUnderTheCatalogKey() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        route(apple: { (200, catalogJSON(lyrics: sampleTTML)) }, lrclib: { (404, Data()) })

        let service = makeService(credentials: FakeAppleCredentials(), dir: dir)
        _ = try await service.lyrics(for: state(catalogID: "1757558454"))
        let firstCount = StubURLProtocol.requests.count

        let again = try await service.lyrics(for: state(catalogID: "1757558454"))
        #expect(again == .syncedTTML(sampleTTML))
        #expect(StubURLProtocol.requests.count == firstCount)

        let cache = LyricsCache(directory: dir)
        #expect(cache.lookup(signature: LyricsService.catalogKey("1757558454")) == .syncedTTML(sampleTTML))
    }
}
}
