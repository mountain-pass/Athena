import Foundation

/// Typed convenience wrappers over the raw Gateway RPC surface.
extension GatewayClient {

    // MARK: Health / status

    func health() async throws -> JSONValue { try await request("health") }
    func status() async throws -> JSONValue { try await request("status") }
    func lastHeartbeat() async throws -> JSONValue { try await request("last-heartbeat") }

    // MARK: Chat
    // Athena uses one primary session for the main chat window.

    static let mainSessionKey = "athena-main"

    func chatHistory(sessionKey: String = mainSessionKey, limit: Int = 200) async throws -> JSONValue {
        try await request("chat.history", .from(["sessionKey": sessionKey, "limit": limit]))
    }

    /// Send a user message. Attachments are base64 payloads the gateway can ingest
    /// (images/video/audio). Streaming updates arrive as `chat`/`agent` events.
    func chatSend(_ text: String,
                  sessionKey: String = mainSessionKey,
                  attachments: [ChatAttachment] = []) async throws -> JSONValue {
        var params: [String: Any?] = [
            "sessionKey": sessionKey,
            "message": text,
            "idempotencyKey": UUID().uuidString,
        ]
        if !attachments.isEmpty {
            params["attachments"] = attachments.map { att in
                [
                    "type": att.kind.rawValue,
                    "fileName": att.fileName,
                    "mimeType": att.mimeType,
                    "content": att.data.base64EncodedString(),
                ] as [String: Any?]
            }
        }
        return try await request("chat.send", .from(params))
    }

    func chatAbort(sessionKey: String = mainSessionKey) async throws {
        _ = try await request("chat.abort", .from(["sessionKey": sessionKey]))
    }

    // MARK: Cron (scheduled jobs)

    func cronList() async throws -> [JSONValue] {
        let res = try await request("cron.list")
        return res["jobs"]?.arrayValue ?? res.arrayValue ?? []
    }

    /// schedule: cron expression, e.g. "0 7 * * *" for 07:00 daily.
    func cronAdd(name: String, schedule: String, prompt: String, enabled: Bool = true) async throws -> JSONValue {
        try await request("cron.add", .from([
            "name": name,
            "schedule": ["kind": "cron", "expr": schedule],
            "payload": ["kind": "agentTurn", "message": prompt],
            "enabled": enabled,
        ]))
    }

    func cronUpdate(id: String, patch: JSONValue) async throws -> JSONValue {
        var p = patch.objectValue ?? [:]
        p["id"] = .string(id)
        return try await request("cron.update", .object(p))
    }

    func cronRemove(id: String) async throws {
        _ = try await request("cron.remove", .from(["id": id]))
    }

    func cronRunNow(id: String) async throws {
        _ = try await request("cron.run", .from(["id": id]))
    }

    // MARK: TTS (server-side, optional — Athena defaults to local AVSpeech)

    func ttsStatus() async throws -> JSONValue { try await request("tts.status") }

    // MARK: Onboarding wizard (drives `openclaw onboard` over RPC)

    func wizardStart() async throws -> JSONValue { try await request("wizard.start") }
    func wizardStatus() async throws -> JSONValue { try await request("wizard.status") }
    func wizardNext(answer: JSONValue) async throws -> JSONValue {
        try await request("wizard.next", .from(["answer": answer]))
    }
    func wizardCancel() async throws { _ = try await request("wizard.cancel") }

    // MARK: Config

    func configGet() async throws -> JSONValue { try await request("config.get") }
    func configPatch(_ partial: JSONValue) async throws -> JSONValue {
        try await request("config.patch", .from(["config": partial]))
    }
}

struct ChatAttachment: Identifiable {
    enum Kind: String { case image, video, file, audio }
    let id = UUID()
    let kind: Kind
    let fileName: String
    let mimeType: String
    let data: Data
}
