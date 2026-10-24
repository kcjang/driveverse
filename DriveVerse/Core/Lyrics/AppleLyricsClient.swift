import Foundation

/// What a catalog request needs: the credentials, and which storefront and
/// language to ask in. Both matter — the same id is "정국" on kr and
/// "Jung Kook" on us, and the lyrics follow the same tag.
struct AppleCatalogContext: Equatable {
    let headers: [String: String]
    let storefront: String
    let language: String
}

// MARK: - Catalog response
//
// Only the slice that carries lyrics. Shape:
// data[0].relationships.lyrics.data[0].attributes.ttml, with
// "syllable-lyrics" as a sibling relationship.

struct CatalogSongsResponse: Decodable {
    struct Song: Decodable {
        struct Relationships: Decodable {
            let lyrics: LyricsRelationship?
            let syllableLyrics: LyricsRelationship?

            enum CodingKeys: String, CodingKey {
                case lyrics
                case syllableLyrics = "syllable-lyrics"
            }
        }
        let relationships: Relationships?
    }

    struct LyricsRelationship: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable { let ttml: String? }
            let attributes: Attributes?
        }
        let data: [Item]?

        var firstTTML: String? {
            data?.compactMap(\.attributes?.ttml).first { !$0.isEmpty }
        }
    }

    let data: [Song]
}

@MainActor
protocol AppleMusicCredentialProviding: AnyObject {
    var isConnected: Bool { get }
    func catalogContext() async throws -> AppleCatalogContext
    func handleUnauthorized() async
}

extension AppleMusicAuth: AppleMusicCredentialProviding {}

/// Reads lyrics straight from Apple's catalog, keyed by the exact track id
/// MPMediaItem already hands us. No title matching, no duration window, no
/// choosing between community uploads — the three things that produce every
/// wrong or missing lyric on the LRCLIB path.
///
/// ⚠️ This is Apple's internal web-player API, outside the terms of service
/// and with no stability guarantee. Every failure here is non-fatal by
/// design: the caller falls back to LRCLIB rather than leaving a driver
/// with no lyrics.
struct AppleLyricsClient {
    enum ClientError: Error, Equatable {
        case badStatus(Int)
    }

    private let session: URLSession
    private let credentials: any AppleMusicCredentialProviding

    init(session: URLSession = .shared, credentials: any AppleMusicCredentialProviding) {
        self.session = session
        self.credentials = credentials
    }

    // MARK: - Pure helpers

    static func url(catalogID: String, storefront: String, language: String) -> URL? {
        var components = URLComponents(
            string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/songs/\(catalogID)"
        )
        components?.queryItems = [
            // Both relationships: line-timed and word-timed. Apple does not
            // always carry each one, so ask for both and take what arrives.
            URLQueryItem(name: "include[songs]", value: "lyrics,syllable-lyrics"),
            URLQueryItem(name: "l", value: language),
        ]
        return components?.url
    }

    /// Picks the TTML out of a catalog response.
    ///
    /// Shape (verified against Manzana's reader and the live API):
    /// `data[0].relationships.lyrics.data[0].attributes.ttml`, with
    /// `syllable-lyrics` alongside it. Line-timed is preferred because the
    /// display works a line at a time anyway; syllable-timed is the fallback
    /// for tracks that only carry that.
    static func result(fromCatalogJSON data: Data) -> LyricsFetchResult {
        guard let payload = try? JSONDecoder().decode(CatalogSongsResponse.self, from: data),
              let song = payload.data.first else { return .notFound }

        let ttml = song.relationships?.lyrics?.firstTTML
            ?? song.relationships?.syllableLyrics?.firstTTML
        guard let ttml, !ttml.isEmpty else { return .notFound }

        // A document with no timings at all is still worth showing unsynced.
        if TTMLParser.parse(ttml).isEmpty {
            let plain = TTMLParser.plainText(ttml)
            return plain.isEmpty ? .notFound : .plain(plain)
        }
        return .syncedTTML(ttml)
    }

    // MARK: - Request

    func lyrics(catalogID: String) async throws -> LyricsFetchResult {
        let context = try await credentials.catalogContext()
        guard let url = Self.url(
            catalogID: catalogID,
            storefront: context.storefront,
            language: context.language
        ) else {
            return .notFound
        }

        var request = URLRequest(url: url)
        for (key, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            return Self.result(fromCatalogJSON: data)
        case 404:
            return .notFound
        case 401, 403:
            await credentials.handleUnauthorized()
            throw ClientError.badStatus(http.statusCode)
        default:
            throw ClientError.badStatus(http.statusCode)
        }
    }
}
