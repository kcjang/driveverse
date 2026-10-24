import Testing
@testable import DriveVerse

@Suite struct LyricsMatcherTests {
    @Test func specNormalizationCase() {
        #expect(LyricsMatcher.normalizeTitle("Song (feat. X) - Remix") == "song")
    }

    @Test func remasteredSuffixStripped() {
        #expect(LyricsMatcher.normalizeTitle("Bohemian Rhapsody (Remastered 2011)") == "bohemian rhapsody")
    }

    @Test func dashSuffixStripped() {
        #expect(LyricsMatcher.normalizeTitle("Track - Radio Edit") == "track")
        #expect(LyricsMatcher.normalizeTitle("Heroes - 2017 Remaster") == "heroes")
    }

    @Test func featWithoutParensStripped() {
        #expect(LyricsMatcher.normalizeTitle("Umbrella feat. Jay-Z") == "umbrella")
        #expect(LyricsMatcher.normalizeTitle("Umbrella ft. Jay-Z") == "umbrella")
        #expect(LyricsMatcher.normalizeTitle("Umbrella featuring Jay-Z") == "umbrella")
    }

    @Test func bracketSuffixStripped() {
        #expect(LyricsMatcher.normalizeTitle("Song [Live at Wembley]") == "song")
    }

    @Test func plainTitleUntouched() {
        #expect(LyricsMatcher.normalizeTitle("Yesterday") == "yesterday")
    }

    @Test func wordContainingFtNotMangled() {
        // "soft" contains "ft" — markers require surrounding spaces.
        #expect(LyricsMatcher.normalizeTitle("Soft Spot") == "soft spot")
    }

    @Test func artistFeatStripped() {
        #expect(LyricsMatcher.normalizeArtist("Rihanna feat. JAY-Z") == "rihanna")
        #expect(LyricsMatcher.normalizeArtist("Calvin Harris (with Dua Lipa)") == "calvin harris")
    }

    @Test func signatureStableAcrossVariants() {
        let a = LyricsMatcher.signature(title: "Song (Remastered)", artist: "Artist", durationMs: 200_000)
        let b = LyricsMatcher.signature(title: "Song", artist: "Artist", durationMs: 201_000)
        #expect(a == b)
    }

    @Test func signatureDiffersByDuration() {
        let a = LyricsMatcher.signature(title: "Song", artist: "Artist", durationMs: 200_000)
        let b = LyricsMatcher.signature(title: "Song", artist: "Artist", durationMs: 260_000)
        #expect(a != b)
    }

    /// Album subtitles are part of the record's identity — unlike track
    /// titles, where " - Remastered" is noise. normalizeTitle used to be
    /// reused here and cut "Help! - Remastered" down to "help!".
    @Test func albumKeepsItsDashSuffix() {
        #expect(LyricsMatcher.normalizeAlbum("Help! - Remastered") == "help! - remastered")
        #expect(LyricsMatcher.normalizeAlbum("Abbey Road (2019 Mix)") == "abbey road")
        #expect(LyricsMatcher.normalizeAlbum("  OK   Computer ") == "ok computer")
    }

    @Test func cacheSignaturesCoverNeighbouringBuckets() {
        let sigs = LyricsMatcher.cacheSignatures(title: "T", artist: "A", durationMs: 200_000)
        #expect(sigs.first == LyricsMatcher.signature(title: "T", artist: "A", durationMs: 200_000))
        #expect(sigs.contains("t|a|39"))
        #expect(sigs.contains("t|a|40"))
        #expect(sigs.contains("t|a|41"))
    }

    /// Bucket -1 means "duration unknown"; a very short track must not
    /// alias onto it.
    @Test func cacheSignaturesNeverAliasTheUnknownDurationKey() {
        let sigs = LyricsMatcher.cacheSignatures(title: "T", artist: "A", durationMs: 1_000)
        #expect(sigs == ["t|a|0", "t|a|1"])
    }

    @Test func cacheSignaturesWithoutDurationIsJustTheOneKey() {
        #expect(LyricsMatcher.cacheSignatures(title: "T", artist: "A", durationMs: nil) == ["t|a|-1"])
    }

    @Test func signatureWithoutDuration() {
        let s = LyricsMatcher.signature(title: "Song", artist: "Artist", durationMs: nil)
        #expect(s == "song|artist|-1")
    }
}
