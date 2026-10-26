import Foundation

/// Thin JSON client for the Hi Dicky backend. Attaches the Supabase
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
        /// Circle-to-ask: the circled part of the screenshot (0..1, top-left origin) and its enlarged crop.
        var region: RegionBox?
        var regionCrop: String?
    }
    struct RegionBox: Encodable { var x: Double; var y: Double; var w: Double; var h: Double }
    struct HistoryTurn: Codable { var role: String; var text: String }
    struct Box: Decodable { var x: Double; var y: Double; var w: Double; var h: Double }
    struct Handoff: Decodable { var task: String; var agent_hint: String? }
    struct Target: Decodable { var element_id: Int?; var box: Box?; var kind: String; var label: String? }
    struct ChatResponse: Decodable {
        var text: String
        var element_id: Int?
        var box: Box?
        var handoff: Handoff?
        var targets: [Target]?
        var follow_ups: [String]?
        var clarify: Bool?
    }
    struct InterviewTurn: Codable { var role: String; var text: String }
    struct InterviewRequest: Encodable { var turns: [InterviewTurn]; var existingNames: [String] }
    struct InterviewBrief: Decodable { var name: String; var purpose: String; var notes: String; var first_messages: [String] }
    struct InterviewResponse: Decodable { var reply: String; var done: Bool; var brief: InterviewBrief? }
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

    private struct VoiceBody: Encodable { var voice: String; var language: String }

    func mintRealtimeSession(voice: String, language: String) async throws -> RealtimeGrant {
        try await post("v1/realtime/session", body: VoiceBody(voice: voice, language: language))
    }

    private struct PreviewBody: Encodable { var voice: String }

    /// MP3 bytes of a short sample in the given voice.
    func voicePreview(voice: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/voice/preview"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await tokenProvider() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(PreviewBody(voice: voice))
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.app.info("POST v1/voice/preview -> \(status) \(data.count) bytes")
        guard (200..<300).contains(status) else { throw Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
    }

    func interview(turns: [InterviewTurn], existingNames: [String]) async throws -> InterviewResponse {
        try await post("v1/interview", body: InterviewRequest(turns: turns, existingNames: existingNames))
    }

    struct DictationGrant: Decodable { var provider: String; var key: String?; var url: String?; var expiresAt: String? }
    struct DictationContext: Encodable { var appName: String?; var fieldRole: String?; var fieldTitle: String?; var before: String? }
    private struct CleanupRequest: Encodable { var transcript: String; var context: DictationContext; var dictionary: [String] }
    private struct CleanupResponse: Decodable { var text: String }

    func dictationToken() async throws -> DictationGrant {
        try await post("v1/dictation/token", body: EmptyBody())
    }

    func dictationCleanup(transcript: String, context: DictationContext, dictionary: [String]) async throws -> String {
        let r: CleanupResponse = try await post("v1/dictation/cleanup", body: CleanupRequest(transcript: transcript, context: context, dictionary: dictionary))
        return r.text
    }

    struct SuggestionAgent: Encodable { var slug: String; var name: String; var purpose: String; var recent: [String]; var routines: [String] }
    private struct SuggestionsRequest: Encodable { var agents: [SuggestionAgent]; var localDate: String }
    struct SuggestionCard: Decodable, Equatable { var title: String; var task: String; var agent_slug: String; var every_minutes: Int? }
    private struct SuggestionsResponse: Decodable { var cards: [SuggestionCard] }

    func suggestions(agents: [SuggestionAgent]) async throws -> [SuggestionCard] {
        let r: SuggestionsResponse = try await post("v1/suggestions", body: SuggestionsRequest(agents: agents, localDate: Date().formatted(date: .complete, time: .omitted)))
        return r.cards
    }

    struct IntegrationsCatalog: Decodable { var configured: Bool; var toolkits: [IntegrationsHost.ComposioToolkit]; var error: String? }
    struct ComposioLink: Decodable { var redirectUrl: String; var connectionRequestId: String }
    struct ComposioSession: Decodable { var url: String?; var headers: [String: String]; var toolkits: [String] }
    private struct ConnectBody: Encodable { var toolkit: String }
    private struct DisconnectBody: Encodable { var connectedAccountId: String }
    private struct OK: Decodable { var ok: Bool }

    func integrationsCatalog() async throws -> IntegrationsCatalog { try await get("v1/integrations/catalog") }
    func integrationsConnect(toolkit: String) async throws -> ComposioLink { try await post("v1/integrations/connect", body: ConnectBody(toolkit: toolkit)) }
    func integrationsDisconnect(connectedAccountId: String) async throws {
        let _: OK = try await post("v1/integrations/disconnect", body: DisconnectBody(connectedAccountId: connectedAccountId))
    }
    func integrationsSession() async throws -> ComposioSession { try await post("v1/integrations/session", body: EmptyBody()) }

    private struct EmptyBody: Encodable {}

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        if let token = await tokenProvider() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.app.info("GET \(path, privacy: .public) -> \(status)")
        guard (200..<300).contains(status) else { throw Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(Response.self, from: data)
    }

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
