import Foundation

/// Thin JSON client for the HeyClicky Clone backend. Attaches the Supabase
/// access token when one is available.
final class BackendClient {
    struct ChatRequest: Encodable {
        var transcript: String
        var screenshot: String?
        var appName: String?
        var elements: [AXElement]
        var history: [HistoryTurn]
        /// Set when the privacy guard withheld the screen; the backend tells the model why.
        var screenWithheld: String?
    }
    struct HistoryTurn: Codable { var role: String; var text: String }
    struct Box: Decodable { var x: Double; var y: Double; var w: Double; var h: Double }
    struct ChatResponse: Decodable {
        var text: String
        var element_id: Int?
        var box: Box?
    }
    struct RealtimeGrant: Decodable {
        var clientSecret: String
        var expiresAt: Double
        var model: String
        var voice: String
        var url: String
    }
    struct Failure: LocalizedError {
        var status: Int
        var body: String
        var errorDescription: String? { "backend \(status): \(body.prefix(200))" }
    }

    let baseURL: URL
    var tokenProvider: () async -> String? = { nil }
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        try await post("v1/chat", body: request)
    }

    func mintRealtimeSession() async throws -> RealtimeGrant {
        try await post("v1/realtime/session", body: EmptyBody())
    }

    private struct EmptyBody: Encodable {}

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await tokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(body)
        let started = Date()
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.app.info("POST \(path, privacy: .public) -> \(status) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        guard (200..<300).contains(status) else {
            throw Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
