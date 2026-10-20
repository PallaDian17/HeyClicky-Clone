import AppKit
import AuthenticationServices
import Supabase

@MainActor
final class AuthManager: ObservableObject {
    enum State: Equatable {
        case unconfigured
        case loading
        case signedOut
        case signedIn(email: String)
    }

    static let redirectURL = URL(string: "heyclickyclone://auth/callback")!

    @Published private(set) var state: State = .loading
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    /// Window the system web-auth sheet attaches to.
    weak var presentationWindow: NSWindow?

    private let client: SupabaseClient?
    private var listenTask: Task<Void, Never>?
    private var webSession: ASWebAuthenticationSession?
    private let presenter = WebAuthPresenter()

    init(config: AppConfig) {
        if let url = config.supabaseURL, let key = config.supabaseAnonKey {
            client = SupabaseClient(
                supabaseURL: url,
                supabaseKey: key,
                options: SupabaseClientOptions(
                    auth: SupabaseClientOptions.AuthOptions(redirectToURL: Self.redirectURL)
                )
            )
            Log.auth.info("Supabase configured for \(url.host ?? "", privacy: .public)")
        } else {
            client = nil
            state = .unconfigured
            Log.auth.notice("Supabase not configured; sign-in disabled")
        }
    }

    var isConfigured: Bool { client != nil }

    /// Current access token for backend calls, refreshed by the SDK when needed.
    func accessToken() async -> String? {
        guard let client else { return nil }
        return try? await client.auth.session.accessToken
    }

    func start() {
        guard let client, listenTask == nil else { return }
        listenTask = Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                self.apply(event: event, session: session)
            }
        }
    }

    private func apply(event: AuthChangeEvent, session: Session?) {
        if let session {
            let user = session.user
            state = .signedIn(email: user.email ?? user.id.uuidString)
        } else {
            state = .signedOut
        }
        Log.auth.info("auth \(event.rawValue, privacy: .public) -> \(String(describing: self.state), privacy: .public)")
    }

    // MARK: - Email + password

    func signIn(email: String, password: String) async {
        await run {
            _ = try await self.client?.auth.signIn(email: email, password: password)
        }
    }

    func signUp(email: String, password: String) async {
        await run {
            let response = try await self.client?.auth.signUp(email: email, password: password)
            if response?.session == nil {
                self.infoMessage = "Check your inbox to confirm the address, then sign in."
            }
        }
    }

    func signOut() async {
        await run {
            try await self.client?.auth.signOut()
        }
    }

    // MARK: - OAuth (Google) through the system browser sheet

    func signInWithGoogle() async {
        guard let client else { return }
        await run {
            let url = try client.auth.getOAuthSignInURL(provider: .google, redirectTo: Self.redirectURL)
            let callback = try await self.presentWebAuth(url: url)
            try await client.auth.session(from: callback)
        }
    }

    private func presentWebAuth(url: URL) async throws -> URL {
        presenter.window = presentationWindow
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.redirectURL.scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? URLError(.cancelled))
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                continuation.resume(throwing: URLError(.cannotConnectToHost))
            }
        }
    }

    /// Callback delivered through the URL scheme when the browser, not the
    /// web-auth sheet, completed the flow (e.g. a magic link).
    func handle(callbackURL: URL) {
        guard let client else { return }
        Task {
            await run { try await client.auth.session(from: callbackURL) }
        }
    }

    // MARK: - Helpers

    private func run(_ work: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        infoMessage = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch let error as URLError where error.code == .cancelled {
            // User closed the sheet; not an error worth showing.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            Log.auth.error("\(String(describing: error), privacy: .public)")
        }
    }
}

/// Non-isolated adapter so the ASWebAuthenticationSession protocol requirement
/// does not inherit the manager's main-actor isolation.
final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    weak var window: NSWindow?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window { return window }
        return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
