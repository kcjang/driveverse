#if os(iOS)
import SwiftUI
import WebKit

/// Signs the user in to music.apple.com and hands back the
/// `media-user-token` cookie Apple sets on success.
///
/// Nothing is typed, read or stored by the app here — the sheet shows
/// Apple's own sign-in page, and the only thing taken from it afterwards is
/// that one cookie.
struct AppleMusicSignInSheet: View {
    let onToken: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var finished = false

    var body: some View {
        NavigationStack {
            AppleMusicWebView { token in
                guard !finished else { return }
                finished = true
                onToken(token)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign in to Apple Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct AppleMusicWebView: UIViewRepresentable {
    let onToken: (String) -> Void

    /// music.apple.com bounces an iOS browser into the Music app, which
    /// would end the flow before a cookie is ever set. A desktop user agent
    /// keeps the web player in the sheet.
    private static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The default (persistent) store is required: sign-in spans several
        // redirects and often a 2FA round trip.
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.desktopUserAgent
        webView.navigationDelegate = context.coordinator

        let cookieStore = configuration.websiteDataStore.httpCookieStore
        cookieStore.add(context.coordinator)
        context.coordinator.cookieStore = cookieStore

        webView.load(URLRequest(url: URL(string: "https://music.apple.com/login")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cookieStore?.remove(coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        private let onToken: (String) -> Void
        private var delivered = false
        weak var cookieStore: WKHTTPCookieStore?

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        /// Apple can set the cookie without a navigation landing, so watch
        /// the store as well as the page.
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in await self.check(cookieStore) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let store = cookieStore else { return }
            Task { @MainActor in await self.check(store) }
        }

        @MainActor
        private func check(_ cookieStore: WKHTTPCookieStore) async {
            guard !delivered else { return }
            let cookies = await cookieStore.allCookies()
            guard let token = AppleMusicCookie.mediaUserToken(from: cookies) else { return }
            delivered = true
            onToken(token)
        }
    }
}
#endif
