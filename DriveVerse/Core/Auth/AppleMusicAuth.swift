import Foundation
import Combine
import Security
import os
#if canImport(WebKit)
import WebKit
#endif

// MARK: - Errors

enum AppleMusicAuthError: Error, Equatable {
    /// No usable developer token could be lifted from the web player.
    case developerTokenUnavailable
    /// Signed out, or the cookie was never captured.
    case notConnected
    /// Apple rejected the user token — sign in again.
    case userTokenRejected
    case http(Int)
}

// MARK: - Developer token (pure)

/// The web player's own API token, which amp-api requires alongside the
/// user's cookie.
///
/// Manzana looks for the literal prefix `eyJh` (base64 of `{"a`, i.e. a JWT
/// whose header opens with `"alg"`) and takes whatever follows. That broke:
/// today's tokens open with `"typ"`, so the prefix is `eyJ0` and the search
/// finds nothing. The bundle also carries unrelated JWTs — checked against
/// amp-api, one of the three answers 401 — so position or length is not a
/// safe selector either.
///
/// So: match the full JWT shape, decode each payload, and order candidates by
/// issuer. The caller tries them in order and keeps the first that works,
/// which means a future reshuffle costs a wasted request rather than an
/// outage.
enum AppleDeveloperToken {
    static let browseURL = URL(string: "https://music.apple.com/us/browse")!
    /// Issuer of the token the web player actually calls amp-api with.
    static let preferredIssuer = "AMPWebPlay"

    /// `index~ea66e33958` out of `…/assets/index~ea66e33958.js`.
    static func bundleSuffix(fromBrowseHTML html: String) -> String? {
        guard let range = html.range(of: #"(?<=index)[A-Za-z0-9~._-]+(?=\.js")"#, options: .regularExpression) else {
            return nil
        }
        return String(html[range])
    }

    static func bundleURL(suffix: String) -> URL? {
        URL(string: "https://music.apple.com/assets/index\(suffix).js")
    }

    /// Every JWT in the bundle, preferred issuer first, de-duplicated and
    /// otherwise in the order found.
    static func candidates(fromBundle js: String) -> [String] {
        let pattern = #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#
        var seen = Set<String>()
        var found: [String] = []
        var cursor = js.startIndex
        while let range = js.range(of: pattern, options: .regularExpression, range: cursor..<js.endIndex) {
            let token = String(js[range])
            if seen.insert(token).inserted { found.append(token) }
            cursor = range.upperBound
        }
        return found.sorted { lhs, rhs in
            (issuer(of: lhs) == preferredIssuer ? 0 : 1) < (issuer(of: rhs) == preferredIssuer ? 0 : 1)
        }
    }

    static func payload(of jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    static func issuer(of jwt: String) -> String? {
        payload(of: jwt)?["iss"] as? String
    }

    static func expiry(of jwt: String) -> Date? {
        guard let exp = payload(of: jwt)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Treat a token as spent slightly early so a drive doesn't start on one
    /// that dies mid-song.
    static func isUsable(_ jwt: String, now: Date, margin: TimeInterval = 3600) -> Bool {
        guard let expiry = expiry(of: jwt) else { return false }
        return now.addingTimeInterval(margin) < expiry
    }
}

// MARK: - Storefront (pure)

/// Which catalog the user's account reads, and in which language. The same
/// song is "정국" on `kr` and "Jung Kook" on `us`, and lyrics follow suit, so
/// this is not optional decoration.
struct AppleMusicStorefront: Equatable {
    let id: String
    let language: String

    static func parse(_ data: Data) -> AppleMusicStorefront? {
        struct Payload: Decodable {
            struct Item: Decodable {
                struct Attributes: Decodable { let defaultLanguageTag: String? }
                let id: String
                let attributes: Attributes?
            }
            let data: [Item]
        }
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: data),
              let first = decoded.data.first else { return nil }
        return AppleMusicStorefront(
            id: first.id,
            language: first.attributes?.defaultLanguageTag ?? "en-US"
        )
    }
}

// MARK: - Cookie extraction (pure)

enum AppleMusicCookie {
    static let name = "media-user-token"

    /// Apple sets the cookie on a few hosts during sign-in; any of them
    /// carries the same value, so take the first non-empty one.
    static func mediaUserToken(from cookies: [HTTPCookie]) -> String? {
        cookies
            .first { $0.name == name && !$0.value.isEmpty }?
            .value
    }
}

// MARK: - Keychain

/// Separate from the Spotify store: different service, different shape (a
/// bare string, not a Codable token pair).
final class AppleMusicTokenStore {
    enum StoreError: Error, Equatable { case unableToStore(OSStatus) }

    private let service = "com.kichang.driveverse.applemusic"
    private let account = AppleMusicCookie.name

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = Data(token.utf8)
        // Drive Mode reads this while the phone is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.unableToStore(status) }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Auth manager

/// Owns both credentials amp-api needs: the scraped developer token and the
/// user's `media-user-token` cookie, plus the storefront they resolve to.
///
/// ⚠️ This reaches Apple Music's internal web-player API with a token lifted
/// out of Apple's own JavaScript. It is outside the terms of service and has
/// no stability guarantee — see the README note. Every failure path here
/// falls back to LRCLIB rather than leaving the driver with no lyrics.
@MainActor
final class AppleMusicAuth: ObservableObject {
    private static let log = Logger(subsystem: "com.kichang.driveverse", category: "applemusic")

    @Published private(set) var isConnected: Bool
    @Published private(set) var storefront: AppleMusicStorefront?
    @Published var needsReconnect = false

    private let store: AppleMusicTokenStore
    private let session: URLSession
    private var developerToken: String?
    var now: () -> Date = Date.init

    init(store: AppleMusicTokenStore = AppleMusicTokenStore(), session: URLSession = .shared) {
        self.store = store
        self.session = session
        self.isConnected = store.load() != nil
    }

    var userToken: String? { store.load() }

    /// Called by the sign-in sheet once the cookie shows up.
    func adopt(userToken: String) async {
        do {
            try store.save(userToken)
        } catch {
            Self.log.error("keychain save failed: \(String(describing: error), privacy: .public)")
            return
        }
        isConnected = true
        needsReconnect = false
        _ = try? await refreshStorefront()
    }

    func disconnect() {
        store.clear()
        developerToken = nil
        storefront = nil
        isConnected = false
        needsReconnect = false
#if canImport(WebKit)
        Task { await Self.clearWebSession() }
#endif
    }

    /// Headers for an amp-api call, acquiring the developer token if needed.
    func authorizedHeaders() async throws -> [String: String] {
        guard let userToken = store.load() else {
            if isConnected { needsReconnect = true }
            throw AppleMusicAuthError.notConnected
        }
        let developer = try await currentDeveloperToken()
        return [
            "authorization": "Bearer \(developer)",
            "media-user-token": userToken,
            "origin": "https://music.apple.com",
            "referer": "https://music.apple.com/",
            "accept": "application/json",
        ]
    }

    @discardableResult
    func refreshStorefront() async throws -> AppleMusicStorefront {
        var request = URLRequest(url: URL(string: "https://amp-api.music.apple.com/v1/me/storefront")!)
        for (key, value) in try await authorizedHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                needsReconnect = true
                throw AppleMusicAuthError.userTokenRejected
            }
            throw AppleMusicAuthError.http(http.statusCode)
        }
        guard let parsed = AppleMusicStorefront.parse(data) else {
            throw AppleMusicAuthError.http(200)
        }
        storefront = parsed
        needsReconnect = false
        return parsed
    }

    // MARK: Developer token

    private func currentDeveloperToken() async throws -> String {
        if let token = developerToken, AppleDeveloperToken.isUsable(token, now: now()) {
            return token
        }
        let token = try await fetchDeveloperToken()
        developerToken = token
        return token
    }

    /// Scrapes the web player, then validates candidates against a public
    /// catalog read — the cheapest call that distinguishes the right token
    /// from the bundle's other JWTs — and keeps the first that answers 200.
    private func fetchDeveloperToken() async throws -> String {
        let (htmlData, _) = try await session.data(from: AppleDeveloperToken.browseURL)
        guard let html = String(data: htmlData, encoding: .utf8),
              let suffix = AppleDeveloperToken.bundleSuffix(fromBrowseHTML: html),
              let bundleURL = AppleDeveloperToken.bundleURL(suffix: suffix) else {
            throw AppleMusicAuthError.developerTokenUnavailable
        }
        let (jsData, _) = try await session.data(from: bundleURL)
        guard let js = String(data: jsData, encoding: .utf8) else {
            throw AppleMusicAuthError.developerTokenUnavailable
        }

        for candidate in AppleDeveloperToken.candidates(fromBundle: js)
        where AppleDeveloperToken.isUsable(candidate, now: now()) {
            if await probe(candidate) { return candidate }
        }
        throw AppleMusicAuthError.developerTokenUnavailable
    }

    /// A known catalog song; 200 means this token is the API one.
    private func probe(_ token: String) async -> Bool {
        var request = URLRequest(
            url: URL(string: "https://amp-api.music.apple.com/v1/catalog/us/songs/1450330685")!
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "origin")
        request.timeoutInterval = 15
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

#if canImport(WebKit)
    /// Signing out should not leave the web session behind for the next
    /// sign-in to silently reuse.
    static func clearWebSession() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let apple = records.filter { $0.displayName.contains("apple.com") }
        await store.removeData(ofTypes: types, for: apple)
    }
#endif
}
