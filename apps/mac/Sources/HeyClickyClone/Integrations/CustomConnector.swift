import Foundation
import Security

/// A user-added remote MCP server the Clickys may call: a name, an HTTP MCP
/// endpoint and how it is authorised. Tokens live in the Keychain, not here.
struct CustomConnector: Codable, Identifiable, Equatable {
    enum Auth: String, Codable, CaseIterable, Identifiable {
        case none, bearer, oauth
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "No sign-in"
            case .bearer: return "Access token"
            case .oauth: return "Sign in (OAuth)"
            }
        }
    }

    struct OAuthRegistration: Codable, Equatable {
        var authorizationEndpoint: String
        var tokenEndpoint: String
        var registrationEndpoint: String?
        var clientID: String
        var scopes: [String] = []
        /// RFC 8707 resource indicator (the MCP URL) when the server publishes protected-resource metadata.
        var resource: String?
    }

    var id: UUID
    var name: String
    var url: String
    var auth: Auth
    var enabled = true
    /// Tools whose names say send / delete / pay stay blocked until this is on.
    var allowSensitiveActions = false
    var oauth: OAuthRegistration?
    var toolNames: [String] = []
    var lastChecked: Date?
    var lastError: String?
    var createdAt: Date

    /// The MCP server name an agent sees: `mcp__<slug>__<tool>`.
    var slug: String {
        let base = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var s = String(base).split(separator: "-").joined(separator: "-")
        if s.isEmpty { s = "connector" }
        return "c-" + String(s.prefix(24))
    }

    var origin: String? {
        guard let u = URL(string: url), let host = u.host else { return nil }
        let port = u.port.map { ":\($0)" } ?? ""
        return "\(u.scheme ?? "https")://\(host)\(port)"
    }
}

/// What the Keychain holds for a connector.
struct ConnectorTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenType: String = "Bearer"

    /// True when the token expires within the next two minutes.
    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 120
    }
}

/// Generic-password items under one service; account = connector id.
enum Keychain {
    static let service = "com.ashish.heyclickyclone.connectors"

    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
