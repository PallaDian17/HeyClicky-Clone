import Foundation

/// Talks Streamable HTTP MCP just far enough to list a server's tools:
/// initialize → notifications/initialized → tools/list.
enum MCPProbe {
    enum Failure: LocalizedError {
        case badURL, unauthorized, http(Int, String), protocolError(String)
        var errorDescription: String? {
            switch self {
            case .badURL: return "That is not a valid URL."
            case .unauthorized: return "The server wants a sign-in (401)."
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(140))"
            case .protocolError(let why): return "Not an MCP server: \(why)"
            }
        }
    }

    struct Result { var serverName: String?; var tools: [String] }

    static func listTools(url: String, bearer: String?) async throws -> Result {
        guard let endpoint = URL(string: url), endpoint.scheme?.hasPrefix("http") == true else { throw Failure.badURL }
        var sessionID: String?

        let initResult = try await call(endpoint, bearer: bearer, session: &sessionID, body: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                       "clientInfo": ["name": "HeyClickyClone", "version": AppConfig.version]],
        ])
        let serverName = ((initResult["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String
        _ = try? await call(endpoint, bearer: bearer, session: &sessionID, body: ["jsonrpc": "2.0", "method": "notifications/initialized"], expectResult: false)

        let listResult = try await call(endpoint, bearer: bearer, session: &sessionID, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
        let tools = ((listResult["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return Result(serverName: serverName, tools: tools)
    }

    private static func call(_ url: URL, bearer: String?, session: inout String?, body: [String: Any], expectResult: Bool = true) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw Failure.protocolError("no HTTP response") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { session = sid }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode, String(decoding: data, as: UTF8.self)) }
        guard expectResult else { return [:] }
        let text = String(decoding: data, as: UTF8.self)
        // Either a JSON body or an SSE stream whose `data:` lines carry the JSON-RPC message.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return try check(obj) }
        for line in text.split(separator: "\n") where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], obj["id"] != nil { return try check(obj) }
        }
        throw Failure.protocolError("unreadable response")
    }

    private static func check(_ obj: [String: Any]) throws -> [String: Any] {
        if let err = obj["error"] as? [String: Any] {
            throw Failure.protocolError((err["message"] as? String) ?? "error \(err["code"] ?? "?")")
        }
        return obj
    }
}
