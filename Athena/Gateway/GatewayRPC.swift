import Foundation
import AppKit
import UniformTypeIdentifiers

/// Typed convenience wrappers over the raw Gateway RPC surface.
extension GatewayClient {

    // MARK: Health / status

    func health() async throws -> JSONValue { try await request("health") }
    func status() async throws -> JSONValue { try await request("status") }
    func lastHeartbeat() async throws -> JSONValue { try await request("last-heartbeat") }

    // MARK: Chat
    // Athena uses one primary session for the main chat window.

    static let mainSessionKey = "athena-main"

    /// Does this session key refer to the main chat?
    ///
    /// The gateway uses TWO forms for the same session: RPC responses carry
    /// the bare key ("athena-main"), while events carry it fully qualified
    /// ("agent:main:athena-main"). Comparing against the bare key alone
    /// silently discarded every streamed event — replies only ever appeared
    /// via history polling, and the turn never registered as finished.
    ///
    /// Sub-sessions must still be excluded: cron runs look like
    /// "agent:main:cron:<jobId>:run:<runId>", which correctly fails both tests.
    static func isMainSession(_ key: String) -> Bool {
        key == mainSessionKey || key.hasSuffix(":" + mainSessionKey)
    }

    func chatHistory(sessionKey: String = mainSessionKey, limit: Int = 200) async throws -> JSONValue {
        try await request("chat.history", .from(["sessionKey": sessionKey, "limit": limit]))
    }

    /// Send a user message. Attachments are base64 payloads the gateway can ingest
    /// (images/video/audio). Streaming updates arrive as `chat`/`agent` events.
    func chatSend(_ text: String,
                  sessionKey: String = mainSessionKey,
                  attachments: [ChatAttachment] = []) async throws -> JSONValue {
        // Base64-encoding a 20MB video on the main thread stalls the UI for
        // seconds — build the whole payload off-main.
        let params: JSONValue = await Task.detached(priority: .userInitiated) {
            var dict: [String: Any?] = [
                "sessionKey": sessionKey,
                "message": text,
                "idempotencyKey": UUID().uuidString,
            ]
            if !attachments.isEmpty {
                dict["attachments"] = attachments.map { att in
                    [
                        "type": att.kind.rawValue,
                        "fileName": att.fileName,
                        "mimeType": att.mimeType,
                        "content": att.data.base64EncodedString(),
                    ] as [String: Any?]
                }
            }
            return JSONValue.from(dict)
        }.value

        return try await request("chat.send", params)
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
        try await request("cron.add", .object([
            "name": .string(name),
            "schedule": .object(["kind": .string("cron"), "expr": .string(schedule)]),
            "payload": .object(["kind": .string("agentTurn"), "message": .string(prompt)]),
            "enabled": .bool(enabled),
        ]))
    }

    /// Convenience patch builder matching the gateway's cron schema.
    static func cronPatch(name: String? = nil, schedule: String? = nil,
                          prompt: String? = nil, enabled: Bool? = nil) -> JSONValue {
        var patch: [String: JSONValue] = [:]
        if let name { patch["name"] = .string(name) }
        if let schedule {
            patch["schedule"] = .object(["kind": .string("cron"), "expr": .string(schedule)])
        }
        if let prompt {
            patch["payload"] = .object(["kind": .string("agentTurn"), "message": .string(prompt)])
        }
        if let enabled { patch["enabled"] = .bool(enabled) }
        return .object(patch)
    }

    /// Schema: `{ id, patch: { … } }` — fields must nest under `patch`.
    /// Schema requires changes nested under `patch` — never merged at root.
    /// Built explicitly so no `Any?` bridging can flatten it.
    func cronUpdate(id: String, patch: JSONValue) async throws -> JSONValue {
        try await request("cron.update", .object([
            "id": .string(id),
            "patch": patch,
        ]))
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

struct ChatAttachment: Identifiable, Sendable {
    enum Kind: String, Sendable { case image, video, file, audio }
    let id = UUID()
    let kind: Kind
    let fileName: String
    let mimeType: String
    let data: Data

    var byteLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    /// Reads a file off the main thread — large videos would otherwise freeze
    /// the UI for seconds while `Data(contentsOf:)` blocks.
    static func load(from url: URL) async -> ChatAttachment? {
        await Task.detached(priority: .userInitiated) { () -> ChatAttachment? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let kind: Kind =
                type.conforms(to: .image) ? .image :
                type.conforms(to: .movie) ? .video :
                type.conforms(to: .audio) ? .audio : .file
            return ChatAttachment(
                kind: kind,
                fileName: url.lastPathComponent,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                data: data)
        }.value
    }

    /// Normalizes pasted image bytes to PNG off the main thread.
    static func fromPasteboardImage(data: Data, isPNG: Bool) async -> ChatAttachment? {
        await Task.detached(priority: .userInitiated) { () -> ChatAttachment? in
            let png: Data
            if isPNG {
                png = data
            } else if let rep = NSBitmapImageRep(data: data),
                      let converted = rep.representation(using: .png, properties: [:]) {
                png = converted
            } else {
                return nil
            }
            let stamp = Date().formatted(.dateTime.hour().minute().second())
                .replacingOccurrences(of: ":", with: "-")
            return ChatAttachment(kind: .image,
                                  fileName: "pasted-\(stamp).png",
                                  mimeType: "image/png",
                                  data: png)
        }.value
    }
}
