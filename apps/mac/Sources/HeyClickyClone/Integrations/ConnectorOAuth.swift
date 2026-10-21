import AppKit
import CryptoKit
import Foundation

/// OAuth 2.1 for custom connectors: metadata discovery (RFC 9728 → RFC 8414 /
/// OpenID), dynamic client registration (RFC 7591), PKCE authorization code
/// in the user's browser with the app's URL scheme as the redirect, and refresh.
enum ConnectorOAuth {
    static let redirectURI = "heyclickyclone://integrations/oauth"

    enum Failure: LocalizedError {
        case noMetadata, noRegistration, badState, tokenError(String), cancelled
        var errorDescription: String? {
            switch self {
            case .noMetadata: return "The server publishes no OAuth metadata (.well-known)."
            case .noRegistration: return "The server does not allow apps to register themselves; it needs a client id."
            case .badState: return "The sign-in reply did not match the request."
            case .tokenError(let why): return "Token exchange failed: \(why)"
            case .cancelled: return "Sign-in was cancelled."
            }
        }
    }

    struct Pending {
        var connectorID: UUID
        var state: String
        var verifier: String
        var registration: CustomConnector.OAuthRegistration
    }

    // MARK: - Discovery

    static func discover(mcpURL: String) async throws -> CustomConnector.OAuthRegistration {
        guard let url = URL(string: mcpURL), let host = url.host else { throw Failure.noMetadata }
        let origin = "\(url.scheme ?? "https")://\(host)\(url.port.map { ":\($0)" } ?? "")"

        // 1. Protected-resource metadata names the authorization server(s).
        var issuers: [String] = []
        var resource: String?
        let path = url.path.isEmpty ? "" : url.path
        for candidate in ["\(origin)/.well-known/oauth-protected-resource\(path)", "\(origin)/.well-known/oauth-protected-resource"] {
            if let meta = await fetchJSON(candidate) {
                issuers = (meta["authorization_servers"] as? [String]) ?? []
                resource = meta["resource"] as? String
                if !issuers.isEmpty { break }
            }
        }
        if issuers.isEmpty { issuers = [origin] }

        // 2. Authorization-server metadata.
        for issuer in issuers {
            let base = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
            let issuerPath = URL(string: base)?.path ?? ""
            let issuerOrigin = issuerPath.isEmpty ? base : String(base.dropLast(issuerPath.count))
            for candidate in ["\(issuerOrigin)/.well-known/oauth-authorization-server\(issuerPath)",
                              "\(base)/.well-known/oauth-authorization-server",
                              "\(base)/.well-known/openid-configuration"] {
                guard let meta = await fetchJSON(candidate),
                      let authz = meta["authorization_endpoint"] as? String,
                      let token = meta["token_endpoint"] as? String else { continue }
                let scopes = (meta["scopes_supported"] as? [String]) ?? []
                return CustomConnector.OAuthRegistration(authorizationEndpoint: authz, tokenEndpoint: token,
                                                         registrationEndpoint: meta["registration_endpoint"] as? String,
                                                         clientID: "", scopes: scopes, resource: resource ?? mcpURL)
            }
        }
        throw Failure.noMetadata
    }

    /// Registers this app with the authorization server when it has no client id yet.
    static func register(_ reg: CustomConnector.OAuthRegistration, connectorName: String) async throws -> CustomConnector.OAuthRegistration {
        guard reg.clientID.isEmpty else { return reg }
        guard let endpoint = reg.registrationEndpoint, let url = URL(string: endpoint) else { throw Failure.noRegistration }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "HeyClicky Clone (\(connectorName))",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = obj["client_id"] as? String else {
            throw Failure.tokenError("registration refused (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        var out = reg
        out.clientID = clientID
        return out
    }

    // MARK: - Authorization code + PKCE

    /// Builds the authorization URL; the caller opens it (browser) or fetches it (headless test).
    static func beginAuthorization(connector: CustomConnector, registration: CustomConnector.OAuthRegistration) -> (url: URL, pending: Pending) {
        let verifier = randomString(64)
        let challenge = base64url(SHA256.hash(data: Data(verifier.utf8)))
        let state = randomString(24)
        var comps = URLComponents(string: registration.authorizationEndpoint)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: registration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !registration.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: registration.scopes.joined(separator: " "))) }
        if let resource = registration.resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        comps.queryItems = (comps.queryItems ?? []) + items
        return (comps.url!, Pending(connectorID: connector.id, state: state, verifier: verifier, registration: registration))
    }

    static func exchange(callback: URL, pending: Pending) async throws -> ConnectorTokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
        if let err = q("error") { throw Failure.tokenError(q("error_description") ?? err) }
        guard q("state") == pending.state, let code = q("code") else { throw Failure.badState }
        var form = [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": pending.registration.clientID, "code_verifier": pending.verifier,
        ]
        if let resource = pending.registration.resource { form["resource"] = resource }
        return try await tokenRequest(pending.registration.tokenEndpoint, form: form)
    }

    static func refresh(_ tokens: ConnectorTokens, registration: CustomConnector.OAuthRegistration) async throws -> ConnectorTokens {
        guard let refresh = tokens.refreshToken else { throw Failure.tokenError("no refresh token") }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": registration.clientID]
        if let resource = registration.resource { form["resource"] = resource }
        var fresh = try await tokenRequest(registration.tokenEndpoint, form: form)
        if fresh.refreshToken == nil { fresh.refreshToken = refresh }
        return fresh
    }

    /// Test hook: performs the authorization request without a browser and
    /// returns the redirect the server answered with (only for servers that
    /// auto-approve, such as the bundled mock).
    static func headlessAuthorize(_ url: URL) async throws -> URL {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
        }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        let (_, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, let location = http.value(forHTTPHeaderField: "Location"), let target = URL(string: location) else {
            throw Failure.tokenError("the authorization server did not redirect")
        }
        return target
    }

    // MARK: - Helpers

    private static func tokenRequest(_ endpoint: String, form: [String: String]) async throws -> ConnectorTokens {
        guard let url = URL(string: endpoint) else { throw Failure.tokenError("bad token endpoint") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(form.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.tokenError("unreadable reply") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let access = obj["access_token"] as? String else {
            throw Failure.tokenError((obj["error_description"] as? String) ?? (obj["error"] as? String) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let expires = (obj["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        return ConnectorTokens(accessToken: access, refreshToken: obj["refresh_token"] as? String, expiresAt: expires,
                               tokenType: (obj["token_type"] as? String) ?? "Bearer")
    }

    private static func fetchJSON(_ urlString: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func base64url(_ digest: SHA256.Digest) -> String {
        Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
