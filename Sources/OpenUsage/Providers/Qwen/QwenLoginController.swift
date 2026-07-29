import AppKit
import WebKit

/// The app's first interactive sign-in: a small window hosting the real Qwen Cloud sign-in page in
/// a `WKWebView`. The view rides the **default (persistent, on-disk) website data store** — safe to
/// share because OpenUsage has no other web surface — so once a user has signed in once, a later
/// window opens on an already-live session and capture completes without retyping anything, until
/// the console session itself expires (~30 days).
///
/// Capture is poll-driven rather than delegate-driven: every two seconds the store's cookies are
/// read, and once `login_qwencloud_ticket` appears the session is verified with a live `info.json`
/// call (the same probe the provider uses) before anything is persisted. Closing the window early
/// reports `.signInCancelled` (minimizing does NOT — the window is still open); multiple
/// concurrent `beginSignIn` callers all receive the same outcome.
@MainActor
final class QwenLoginController {
    /// The billing page redirects to the login form when signed out and lands on account content
    /// when signed in — one URL serves both states.
    nonisolated static let signInURL = URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!
    /// The one cookie the whole billing chain cannot work without (verified empirically: it alone
    /// authenticates info.json and every gateway call). Its presence is the "login happened"
    /// signal; the full captured set is still stored for fidelity.
    nonisolated static let requiredCookieName = "login_qwencloud_ticket"
    nonisolated static let pollInterval: Duration = .seconds(2)

    /// At most one sign-in window app-wide; the controller pins itself here while active so the
    /// poll loop and window outlive whoever invoked it.
    private static var activeSignIn: QwenLoginController?

    private let authStore: QwenAuthStore
    private let usageClient: QwenUsageClient
    private var window: NSWindow?
    private var dataStore: WKWebsiteDataStore?
    /// Every caller that asked to sign in while this controller is active — drained together in
    /// `finish`, so a second Sign In click (e.g. the Customize popover reopened mid-sign-in) gets
    /// its completion instead of hanging its "Signing In…" state forever.
    private var completions: [@MainActor (Result<QwenSession, Error>) -> Void] = []
    private var finished = false
    private var windowClosed = false
    private var closeObserver: (any NSObjectProtocol)?

    init(authStore: QwenAuthStore = QwenAuthStore(), usageClient: QwenUsageClient = QwenUsageClient()) {
        self.authStore = authStore
        self.usageClient = usageClient
    }

    /// Open the sign-in window (or join the active one). The completion runs exactly once per
    /// caller on the main actor: `.success` with the persisted session, or a failure
    /// (cancel / save error).
    func beginSignIn(completion: @escaping @MainActor (Result<QwenSession, Error>) -> Void) {
        if let existing = Self.activeSignIn {
            existing.completions.append(completion)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Self.activeSignIn = self
        completions = [completion]

        let dataStore = WKWebsiteDataStore.default()
        self.dataStore = dataStore
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        webView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Qwen Cloud"
        window.contentView = webView
        // Center first, then register autosave: on first launch the centered frame gets saved; on
        // later launches setFrameAutosaveName restores the saved frame and nothing overrides it.
        window.center()
        window.setFrameAutosaveName("QwenSignIn")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // Closing the window ends the attempt (miniaturizing does not — isVisible alone can't
        // tell them apart, so use the close notification).
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowClosed = true }
        }

        webView.load(URLRequest(url: Self.signInURL))
        Task { [weak self] in await self?.pollForSession() }
    }

    /// The poll loop: while the window is up, watch for the required cookie, then verify before
    /// persisting. A verification failure (cookie present but info.json has no secToken yet) simply
    /// keeps polling. Window closed → cancelled.
    private func pollForSession() async {
        while !finished, !windowClosed {
            try? await Task.sleep(for: Self.pollInterval)
            guard !finished, !windowClosed, let dataStore else { break }
            let cookies = await dataStore.httpCookieStore.allCookies()
            guard let header = Self.cookieHeader(from: cookies) else { continue }
            guard await verifySession(cookies: header) else { continue }
            await persist(header: header)
            return
        }
        finish(with: .failure(QwenAuthError.signInCancelled))
    }

    /// True when the captured cookies authenticate a live info.json probe (yields a secToken).
    private func verifySession(cookies: String) async -> Bool {
        do {
            let response = try await usageClient.fetchInfo(cookies: cookies)
            guard (200..<300).contains(response.statusCode) else { return false }
            return QwenUsageMapper.secToken(from: response.body) != nil
        } catch {
            return false
        }
    }

    private func persist(header: String) async {
        let session = QwenSession(cookies: header, region: QwenAuthStore.defaultRegion)
        do {
            try await loadOffMainActor { [authStore] in
                try authStore.saveSession(cookies: session.cookies, region: session.region, source: "webView")
            }
            finish(with: .success(session))
        } catch {
            finish(with: .failure(QwenAuthError.saveFailed))
        }
    }

    /// Resolve every waiting caller with the same outcome and tear down.
    private func finish(with result: Result<QwenSession, Error>) {
        guard !finished else { return }
        finished = true
        if Self.activeSignIn === self { Self.activeSignIn = nil }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        self.closeObserver = nil
        window?.close()
        window = nil
        dataStore = nil
        let completions = self.completions
        self.completions = []
        for completion in completions {
            completion(result)
        }
    }

    /// Join the qwencloud console cookies into one `Cookie` header value. Only cookies on a
    /// qwencloud.com domain are kept, and the result is nil unless the load-bearing
    /// `login_qwencloud_ticket` is among them — so callers get a single "session ready?" check.
    nonisolated static func cookieHeader(from cookies: [HTTPCookie]) -> String? {
        let matching = cookies.filter { isQwenCloudDomain($0.domain) }
        guard matching.contains(where: { $0.name == requiredCookieName }) else { return nil }
        return matching
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// qwencloud.com and any subdomain, tolerating the leading-dot spelling.
    nonisolated static func isQwenCloudDomain(_ domain: String) -> Bool {
        var host = domain
        if host.hasPrefix(".") { host.removeFirst() }
        host = host.lowercased()
        return host == "qwencloud.com" || host.hasSuffix(".qwencloud.com")
    }
}
