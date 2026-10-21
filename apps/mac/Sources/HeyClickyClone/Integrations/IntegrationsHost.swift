import AppKit
import Foundation

/// Everything an agent turn can reach beyond the Mac: Composio toolkits the
/// user connected through the backend, and custom MCP connectors added in
/// Setup. Produces the MCP server entries for a turn and the policy that
/// gates their sensitive tools.
@MainActor
final class IntegrationsHost: ObservableObject {
    struct ComposioToolkit: Decodable, Identifiable, Equatable {
        var slug: String
        var name: String
        var connected: Bool
        var connectedAccountId: String?
        var id: String { slug }
    }

    struct TurnServers {
        var servers: [String: Any] = [:]
        /// MCP server names whose send/delete/pay tools are allowed.
        var sensitiveAllowed: Set<String> = []
        /// Human summary for the preamble: "Gmail, Notion (Composio); Mock notes".
        var summary: [String] = []
    }

    static let composioServerName = "composio"
    static let composioSensitiveKey = "ClickyComposioAllowSensitive"

    @Published private(set) var connectors: [CustomConnector] = []
    @Published private(set) var composioConfigured = false
    @Published private(set) var toolkits: [ComposioToolkit] = []
    @Published private(set) var busy: Set<UUID> = []
    @Published var composioAllowSensitive: Bool {
        didSet { UserDefaults.standard.set(composioAllowSensitive, forKey: Self.composioSensitiveKey) }
    }
    @Published var lastMessage: String?

    private let backend: BackendClient
    private let fileURL: URL
    private var pendingOAuth: ConnectorOAuth.Pending?
    private var composioSession: (url: String, headers: [String: String], toolkits: Set<String>, at: Date)?

    init(backend: BackendClient) {
        self.backend = backend
        fileURL = AppConfig.appSupportDirectory.appendingPathComponent("connectors.json")
        composioAllowSensitive = UserDefaults.standard.bool(forKey: Self.composioSensitiveKey)
        load()
    }

    // MARK: - Custom connectors

    func connector(id: UUID) -> CustomConnector? { connectors.first { $0.id == id } }

    @discardableResult
    func add(name: String, url: String, auth: CustomConnector.Auth, token: String? = nil) -> CustomConnector {
        let connector = CustomConnector(id: UUID(), name: name.trimmingCharacters(in: .whitespaces), url: url.trimmingCharacters(in: .whitespaces),
                                        auth: auth, createdAt: Date())
        connectors.append(connector)
        save()
        if auth == .bearer, let token, !token.isEmpty { setTokens(ConnectorTokens(accessToken: token), for: connector.id) }
        Log.integrations.info("connector added '\(connector.name, privacy: .public)' auth=\(auth.rawValue, privacy: .public)")
        return connector
    }

    func update(_ connector: CustomConnector) {
        guard let i = connectors.firstIndex(where: { $0.id == connector.id }) else { return }
        connectors[i] = connector
        save()
    }

    func remove(_ id: UUID) {
        connectors.removeAll { $0.id == id }
        Keychain.delete(account: id.uuidString)
        save()
    }

    func tokens(for id: UUID) -> ConnectorTokens? {
        guard let data = Keychain.load(account: id.uuidString) else { return nil }
        return try? JSONDecoder().decode(ConnectorTokens.self, from: data)
    }

    func setTokens(_ tokens: ConnectorTokens?, for id: UUID) {
        if let tokens, let data = try? JSONEncoder().encode(tokens) {
            try? Keychain.save(data, account: id.uuidString)
        } else {
            Keychain.delete(account: id.uuidString)
        }
        objectWillChange.send()
    }

    /// One line for the Setup row.
    func status(for connector: CustomConnector) -> String {
        if let err = connector.lastError { return "Problem: \(err)" }
        let signedIn: String
        switch connector.auth {
        case .none: signedIn = "no sign-in needed"
        case .bearer: signedIn = tokens(for: connector.id) == nil ? "needs an access token" : "token saved"
        case .oauth: signedIn = tokens(for: connector.id) == nil ? "needs sign-in" : "signed in"
        }
        let tools = connector.toolNames.isEmpty ? "not tested yet" : "\(connector.toolNames.count) tool\(connector.toolNames.count == 1 ? "" : "s")"
        return "\(signedIn) · \(tools)" + (connector.enabled ? "" : " · off")
    }

    /// Connects to the server and records its tool list (or the error).
    func test(_ id: UUID) async {
        guard var connector = connector(id: id) else { return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            let bearer = try await freshAccessToken(for: connector)
            let result = try await MCPProbe.listTools(url: connector.url, bearer: bearer)
            connector = self.connector(id: id) ?? connector
            connector.toolNames = result.tools
            connector.lastError = nil
            connector.lastChecked = Date()
            update(connector)
            lastMessage = "\(connector.name): \(result.tools.count) tools" + (result.serverName.map { " (\($0))" } ?? "")
            Log.integrations.info("connector test '\(connector.name, privacy: .public)' tools=\(result.tools.count)")
        } catch {
            connector = self.connector(id: id) ?? connector
            connector.lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            connector.lastChecked = Date()
            update(connector)
            Log.integrations.error("connector test '\(connector.name, privacy: .public)' failed: \(connector.lastError ?? "", privacy: .public)")
        }
    }

    /// OAuth sign-in: discover + register once, then authorize. `headless` fetches
    /// the authorization URL directly instead of opening the browser (test servers
    /// that auto-approve only).
    func signIn(_ id: UUID, headless: Bool = false) async {
        guard var connector = connector(id: id), connector.auth == .oauth else { return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            var registration: CustomConnector.OAuthRegistration
            if let known = connector.oauth { registration = known } else { registration = try await ConnectorOAuth.discover(mcpURL: connector.url) }
            registration = try await ConnectorOAuth.register(registration, connectorName: connector.name)
            connector.oauth = registration
            connector.lastError = nil
            update(connector)
            let (url, pending) = ConnectorOAuth.beginAuthorization(connector: connector, registration: registration)
            pendingOAuth = pending
            if headless {
                let callback = try await ConnectorOAuth.headlessAuthorize(url)
                await handleOAuthCallback(callback)
            } else {
                Log.integrations.info("opening browser for '\(connector.name, privacy: .public)' sign-in")
                NSWorkspace.shared.open(url)
            }
        } catch {
            connector.lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            update(connector)
            Log.integrations.error("sign-in '\(connector.name, privacy: .public)' failed: \(connector.lastError ?? "", privacy: .public)")
        }
    }

    /// `heyclickyclone://integrations/oauth?code=…&state=…`
    func handleOAuthCallback(_ url: URL) async {
        guard let pending = pendingOAuth else {
            Log.integrations.notice("oauth callback with nothing pending")
            return
        }
        pendingOAuth = nil
        guard var connector = connector(id: pending.connectorID) else { return }
        do {
            let tokens = try await ConnectorOAuth.exchange(callback: url, pending: pending)
            setTokens(tokens, for: connector.id)
            connector.lastError = nil
            update(connector)
            lastMessage = "Signed in to \(connector.name)"
            Log.integrations.info("signed in '\(connector.name, privacy: .public)' refresh=\(tokens.refreshToken != nil) expires=\(tokens.expiresAt.map { Int($0.timeIntervalSinceNow) } ?? -1)s")
            await test(connector.id)
        } catch {
            connector.lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            update(connector)
            Log.integrations.error("oauth exchange '\(connector.name, privacy: .public)' failed: \(connector.lastError ?? "", privacy: .public)")
        }
    }

    func signOut(_ id: UUID) {
        setTokens(nil, for: id)
        if var c = connector(id: id) { c.toolNames = []; c.lastError = nil; update(c) }
    }

    /// Returns a valid access token for the connector, refreshing when close to expiry.
    private func freshAccessToken(for connector: CustomConnector) async throws -> String? {
        guard connector.auth != .none else { return nil }
        guard let tokens = tokens(for: connector.id) else {
            throw MCPProbe.Failure.unauthorized
        }
        guard connector.auth == .oauth, tokens.needsRefresh, let registration = connector.oauth else { return tokens.accessToken }
        let fresh = try await ConnectorOAuth.refresh(tokens, registration: registration)
        setTokens(fresh, for: connector.id)
        Log.integrations.info("refreshed token for '\(connector.name, privacy: .public)'")
        return fresh.accessToken
    }

    // MARK: - Composio

    func refreshComposio() async {
        do {
            let catalog = try await backend.integrationsCatalog()
            composioConfigured = catalog.configured
            toolkits = catalog.toolkits
            if let err = catalog.error { lastMessage = "Composio: \(err.prefix(120))" }
        } catch {
            Log.integrations.notice("composio catalog unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Opens Composio's hosted connect page for a toolkit; the callback lands on
    /// `heyclickyclone://integrations/composio`.
    func connectComposio(_ slug: String) async {
        do {
            let link = try await backend.integrationsConnect(toolkit: slug)
            guard let url = URL(string: link.redirectUrl) else { return }
            Log.integrations.info("opening Composio connect for \(slug, privacy: .public)")
            NSWorkspace.shared.open(url)
        } catch {
            lastMessage = "Couldn't start \(slug): \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    func disconnectComposio(_ slug: String) async {
        guard let toolkit = toolkits.first(where: { $0.slug == slug }), let id = toolkit.connectedAccountId else { return }
        do {
            try await backend.integrationsDisconnect(connectedAccountId: id)
            composioSession = nil
            await refreshComposio()
        } catch {
            lastMessage = "Couldn't disconnect \(toolkit.name): \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    func handleComposioCallback(_ url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let status = items.first(where: { $0.name == "status" })?.value ?? "?"
        Log.integrations.info("composio callback status=\(status, privacy: .public)")
        composioSession = nil
        await refreshComposio()
        if status == "success" { lastMessage = "Connected." }
    }

    // MARK: - Per-turn

    /// Collects MCP server entries for a turn: a Composio session for the
    /// connected toolkits (cached ~20 min) and every enabled, signed-in connector.
    func prepareForTurn() async -> TurnServers {
        var out = TurnServers()

        let connectedToolkits = Set(toolkits.filter(\.connected).map(\.slug))
        if composioConfigured, !connectedToolkits.isEmpty {
            if let s = composioSession, s.toolkits == connectedToolkits, Date().timeIntervalSince(s.at) < 20 * 60 {
                out.servers[Self.composioServerName] = ["type": "http", "url": s.url, "headers": s.headers]
            } else if let session = try? await backend.integrationsSession(), let url = session.url {
                composioSession = (url, session.headers, Set(session.toolkits), Date())
                out.servers[Self.composioServerName] = ["type": "http", "url": url, "headers": session.headers]
            }
            if out.servers[Self.composioServerName] != nil {
                let names = toolkits.filter(\.connected).map(\.name).joined(separator: ", ")
                out.summary.append("\(names) through the \(Self.composioServerName) server")
                if composioAllowSensitive { out.sensitiveAllowed.insert(Self.composioServerName) }
            }
        }

        for connector in connectors where connector.enabled {
            do {
                let token = try await freshAccessToken(for: connector)
                var entry: [String: Any] = ["type": "http", "url": connector.url]
                if let token { entry["headers"] = ["Authorization": "Bearer \(token)"] }
                out.servers[connector.slug] = entry
                out.summary.append("\(connector.name) (server \(connector.slug))")
                if connector.allowSensitiveActions { out.sensitiveAllowed.insert(connector.slug) }
            } catch {
                Log.integrations.notice("connector '\(connector.name, privacy: .public)' skipped for this turn: \((error as? LocalizedError)?.errorDescription ?? "\(error)", privacy: .public)")
            }
        }
        return out
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        connectors = (try? decoder.decode([CustomConnector].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(connectors) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// Gate for integration tools (`mcp__<server>__<tool>`): tools whose names say
/// they send, delete or pay are blocked until the user allows that server.
struct IntegrationPolicy {
    var sensitiveAllowed: Set<String> = []
    var knownServers: Set<String> = []

    static let sensitiveWords = ["send", "reply", "delete", "remove", "trash", "pay", "purchase", "transfer", "archive", "cancel", "publish"]

    static func split(_ tool: String) -> (server: String, name: String)? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let rest = tool.dropFirst(5)
        guard let sep = rest.range(of: "__") else { return nil }
        return (String(rest[..<sep.lowerBound]), String(rest[sep.upperBound...]))
    }

    static func isSensitive(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let parts = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return sensitiveWords.contains { parts.contains($0) }
    }

    func decide(tool: String) -> PermissionPolicy.Decision {
        guard let (server, name) = Self.split(tool), knownServers.contains(server) else { return .allow }
        if Self.isSensitive(name), !sensitiveAllowed.contains(server) {
            return .deny("\(name) can send, delete or pay, and that is turned off for \(server). Tell the user what you would do; they can allow it in Setup → Integrations.")
        }
        return .allow
    }
}
