import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppModel.pollIntervalKey) private var pollInterval: Double = 5
    @State private var cacheCleared = false
    @State private var showingAppleSignIn = false

    var body: some View {
        Form {
            Section {
                Picker("Preferred source", selection: pinBinding) {
                    ForEach(SourcePin.allCases) { pin in
                        Text(pin.displayName).tag(pin)
                    }
                }
            } header: {
                Text("Source")
            } footer: {
                Text("Automatic prefers Apple Music whenever it's playing (local, exact position), otherwise Spotify. Pin a source to ignore the other.")
            }

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Poll interval")
                        Spacer()
                        Text("\(Int(pollInterval)) s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $pollInterval, in: 3...10, step: 1)
                }
                if model.spotifyConnected {
                    Button("Disconnect Spotify", role: .destructive) {
                        model.disconnectSpotify()
                    }
                }
            } header: {
                Text("Spotify")
            } footer: {
                Text("How often DriveVerse asks Spotify what's playing. Lower is snappier; higher saves battery and API quota. Between reports, lyric timing is extrapolated locally.")
            }

            Section {
                if model.appleLyricsAuth.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let storefront = model.appleLyricsAuth.storefront {
                        LabeledContent("Storefront", value: "\(storefront.id) · \(storefront.language)")
                    }
                    Button("Sign out of Apple Music", role: .destructive) {
                        model.appleLyricsAuth.disconnect()
                    }
                } else {
                    Button("Connect Apple Music") { showingAppleSignIn = true }
                }
            } header: {
                Text("Apple Music lyrics")
            } footer: {
                Text("Optional. Signing in lets DriveVerse read the lyrics Apple already has for a track, matched by its exact catalog ID instead of guessing from the title. Tracks LRCLIB has never heard of start working, and the timings are the ones you're hearing. This uses Apple's internal web-player API, so it is outside Apple Music's terms and can break without notice — LRCLIB stays the fallback either way.")
            }

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Lyric offset")
                        Spacer()
                        Text(offsetLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: offsetBinding,
                        in: Double(-AppModel.lyricOffsetRangeMs)...Double(AppModel.lyricOffsetRangeMs),
                        step: 100
                    )
                    if model.lyricOffsetMs != 0 {
                        Button("Reset to 0") { model.lyricOffsetMs = 0 }
                            .font(.footnote)
                    }
                }
                Toggle("Romanize lyrics", isOn: romanizeBinding)
                Button("Clear lyrics cache") {
                    model.clearLyricsCache()
                    cacheCleared = true
                }
                if cacheCleared {
                    Label("Cache cleared", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Drag the offset right if the lines run ahead of the music, left if they lag behind — LRCLIB timings are only as good as whoever uploaded them. Romanizing rewrites non-Latin lyrics in the alphabet (\"새로운\" becomes \"saeloun\"), which only helps if you can't read the script. Lyrics are cached on this device for at most 30 days.")
            }

            Section {
                EmptyView()
            } header: {
                Text("Drive Mode & battery")
            } footer: {
                Text("Drive Mode keeps DriveVerse awake in the background using a low-power location session, so lyrics keep updating on CarPlay and the lock screen while you drive. Locations are discarded immediately and never stored. It uses extra battery, so it's opt-in. This approach is fine for a personal sideloaded app but would not pass App Store review.")
            }

            Section {
                EmptyView()
            } header: {
                Text("About")
            } footer: {
                Text("DriveVerse is a personal-use app. Lyrics are fetched from the community-run LRCLIB API for private, non-commercial display. Do not distribute this app without a licensed lyrics provider.")
            }
        }
        .navigationTitle("Settings")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAppleSignIn) {
            AppleMusicSignInSheet { token in
                Task { await model.appleLyricsAuth.adopt(userToken: token) }
            }
        }
#endif
    }

    private var pinBinding: Binding<SourcePin> {
        Binding(get: { model.sourcePin }, set: { model.sourcePin = $0 })
    }

    private var romanizeBinding: Binding<Bool> {
        Binding(get: { model.romanizeLyrics }, set: { model.romanizeLyrics = $0 })
    }

    private var offsetBinding: Binding<Double> {
        Binding(get: { Double(model.lyricOffsetMs) }, set: { model.lyricOffsetMs = Int($0) })
    }

    /// "0 s", "+0.5 s", "−1.2 s" — a signed seconds reading at slider step.
    private var offsetLabel: String {
        let seconds = Double(model.lyricOffsetMs) / 1000
        if seconds == 0 { return "0 s" }
        return String(format: "%@%.1f s", seconds > 0 ? "+" : "−", abs(seconds))
    }
}
