import Testing
import Foundation
@testable import DriveVerse

/// Builds a JWT with a real payload; signature is filler since nothing here
/// verifies it — only the issuer and expiry are read.
private func jwt(iss: String, exp: Date) -> String {
    func segment(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    // Written out rather than serialized from a dictionary: key order is what
    // decides the base64 prefix, and a Dictionary does not preserve it.
    let header = segment(#"{"typ":"JWT","alg":"ES256","kid":"97DQU9QUD6"}"#)
    let payload = segment(#"{"iss":"\#(iss)","exp":\#(exp.timeIntervalSince1970),"iat":0}"#)
    return "\(header).\(payload).c2lnbmF0dXJl"
}

@Suite struct AppleDeveloperTokenTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func findsBundleSuffixInBrowseHTML() {
        let html = #"<script type="module" crossorigin src="/assets/index~ea66e33958.js"></script>"#
        #expect(AppleDeveloperToken.bundleSuffix(fromBrowseHTML: html) == "~ea66e33958")
        #expect(AppleDeveloperToken.bundleURL(suffix: "~ea66e33958")?.absoluteString
                == "https://music.apple.com/assets/index~ea66e33958.js")
    }

    @Test func missingBundleReferenceYieldsNil() {
        #expect(AppleDeveloperToken.bundleSuffix(fromBrowseHTML: "<html>nothing here</html>") == nil)
    }

    /// The exact reason Manzana stopped working: it searches for the literal
    /// prefix `eyJh`, which is a JWT header starting with "alg". Apple's
    /// tokens now start with "typ", so that search finds nothing. Matching
    /// the whole JWT shape is indifferent to which claim comes first.
    @Test func findsTokensWhoseHeaderStartsWithTyp() {
        let token = jwt(iss: "AMPWebPlay", exp: now.addingTimeInterval(86_400))
        #expect(token.hasPrefix("eyJ0"), "fixture should reproduce the typ-first header")
        #expect(!token.hasPrefix("eyJh"))

        let bundle = "var x=1;const t=\"\(token)\";export{t};"
        #expect(AppleDeveloperToken.candidates(fromBundle: bundle) == [token])
    }

    /// The bundle carries several JWTs and only one answers amp-api, so the
    /// preferred issuer has to be tried first — length or position is not a
    /// safe selector.
    @Test func preferredIssuerIsOrderedFirst() {
        let other = jwt(iss: "M62YD85FTQ", exp: now.addingTimeInterval(86_400))
        let wanted = jwt(iss: AppleDeveloperToken.preferredIssuer, exp: now.addingTimeInterval(86_400))
        let bundle = "a=\"\(other)\";b=\"\(wanted)\";"

        let ordered = AppleDeveloperToken.candidates(fromBundle: bundle)
        #expect(ordered.first == wanted)
        // The others stay as fallbacks rather than being discarded.
        #expect(ordered.count == 2)
        #expect(ordered.contains(other))
    }

    @Test func duplicatesCollapse() {
        let token = jwt(iss: "AMPWebPlay", exp: now.addingTimeInterval(86_400))
        let bundle = "a=\"\(token)\";b=\"\(token)\";"
        #expect(AppleDeveloperToken.candidates(fromBundle: bundle).count == 1)
    }

    @Test func readsIssuerAndExpiry() {
        let expiry = now.addingTimeInterval(86_400)
        let token = jwt(iss: "AMPWebPlay", exp: expiry)
        #expect(AppleDeveloperToken.issuer(of: token) == "AMPWebPlay")
        let read = try? #require(AppleDeveloperToken.expiry(of: token))
        #expect(abs((read ?? .distantPast).timeIntervalSince(expiry)) < 1)
    }

    @Test func malformedTokensAreRejectedNotCrashed() {
        #expect(AppleDeveloperToken.payload(of: "not.a.jwt") == nil)
        #expect(AppleDeveloperToken.payload(of: "eyJhbGciOiJIUzI1NiJ9") == nil)
        #expect(AppleDeveloperToken.issuer(of: "") == nil)
        #expect(AppleDeveloperToken.expiry(of: "a.b.c") == nil)
    }

    /// Spent an hour early, so a drive does not start on a token that dies
    /// mid-song.
    @Test func usabilityLeavesAMargin() {
        #expect(AppleDeveloperToken.isUsable(jwt(iss: "x", exp: now.addingTimeInterval(7200)), now: now))
        #expect(!AppleDeveloperToken.isUsable(jwt(iss: "x", exp: now.addingTimeInterval(600)), now: now))
        #expect(!AppleDeveloperToken.isUsable(jwt(iss: "x", exp: now.addingTimeInterval(-60)), now: now))
        #expect(!AppleDeveloperToken.isUsable("garbage", now: now))
    }
}

@Suite struct AppleMusicStorefrontTests {
    @Test func parsesIDAndLanguage() {
        let json = Data(#"""
        {"data":[{"id":"kr","type":"storefronts","attributes":{"defaultLanguageTag":"ko-KR","name":"대한민국"}}]}
        """#.utf8)
        #expect(AppleMusicStorefront.parse(json) == AppleMusicStorefront(id: "kr", language: "ko-KR"))
    }

    @Test func missingLanguageFallsBackToEnglish() {
        let json = Data(#"{"data":[{"id":"us","type":"storefronts"}]}"#.utf8)
        #expect(AppleMusicStorefront.parse(json) == AppleMusicStorefront(id: "us", language: "en-US"))
    }

    @Test func emptyOrBrokenPayloadYieldsNil() {
        #expect(AppleMusicStorefront.parse(Data(#"{"data":[]}"#.utf8)) == nil)
        #expect(AppleMusicStorefront.parse(Data("not json".utf8)) == nil)
    }
}

@Suite struct AppleMusicCookieTests {
    private func cookie(name: String, value: String, domain: String = ".apple.com") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: domain, .path: "/",
        ])!
    }

    @Test func picksTheMediaUserToken() {
        let cookies = [
            cookie(name: "geo", value: "KR"),
            cookie(name: AppleMusicCookie.name, value: "Auser-token-value"),
            cookie(name: "dslang", value: "KO-KR"),
        ]
        #expect(AppleMusicCookie.mediaUserToken(from: cookies) == "Auser-token-value")
    }

    /// Apple sets the name with an empty value before sign-in completes;
    /// adopting that would look connected while sending nothing.
    @Test func emptyValueIsNotAToken() {
        let cookies = [cookie(name: AppleMusicCookie.name, value: "")]
        #expect(AppleMusicCookie.mediaUserToken(from: cookies) == nil)
    }

    @Test func absentCookieYieldsNil() {
        #expect(AppleMusicCookie.mediaUserToken(from: []) == nil)
        #expect(AppleMusicCookie.mediaUserToken(from: [cookie(name: "geo", value: "KR")]) == nil)
    }
}
