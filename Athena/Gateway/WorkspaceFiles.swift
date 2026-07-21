import Foundation

/// Reads and writes files in the agent's workspace.
///
/// The `agents.files.*` RPC shape varies between OpenClaw versions — some want
/// `{agentId, name, content}`, others `{agentId, file, content}` or a `files`
/// array, and older builds accepted a bare `path`. Rather than guessing, this
/// helper probes once, remembers what worked, and falls back to asking the
/// agent to write the file itself (it has filesystem tools) when the RPC
/// refuses arbitrary paths.
@MainActor
final class WorkspaceFiles {

    enum WriteMethod: String {
        case filesName      = "agents.files.set(name:)"
        case filesFile      = "agents.files.set(file:)"
        case filesPath      = "agents.files.set(path:)"
        case filesArray     = "agents.files.set(files:[])"
        case toolInvoke     = "tools.invoke(write_file)"
        case agentAssisted  = "agent writes it"
        case unavailable    = "unavailable"
    }

    private let gateway: GatewayClient
    private(set) var agentId: String?
    private(set) var writeMethod: WriteMethod?
    /// Side session so file plumbing never lands in the main transcript.
    static let sessionKey = "athena-files"

    init(gateway: GatewayClient) { self.gateway = gateway }

    // MARK: Agent id

    @discardableResult
    func resolveAgentId() async -> String? {
        if let agentId { return agentId }
        guard let res = try? await gateway.request("agents.list") else { return nil }
        let rows = res["agents"]?.arrayValue ?? res.arrayValue ?? []
        // Prefer the default agent, else the first.
        let match = rows.first { $0["default"]?.boolValue == true } ?? rows.first
        agentId = match?["id"]?.stringValue ?? "main"
        return agentId
    }

    // MARK: Read

    func read(_ path: String) async -> String? {
        let id = await resolveAgentId() ?? "main"

        // Try the documented shapes in order.
        let attempts: [JSONValue] = [
            .from(["agentId": id, "name": path]),
            .from(["agentId": id, "file": path]),
            .from(["agentId": id, "path": path]),
            .from(["path": path]),
        ]
        for params in attempts {
            if let res = try? await gateway.request("agents.files.get", params),
               let text = res["content"]?.stringValue ?? res["text"]?.stringValue
                        ?? res["file"]?["content"]?.stringValue {
                return text
            }
        }

        // Filesystem tools.
        for tool in ["read_file", "fs_read", "file_read"] {
            if let res = try? await gateway.request("tools.invoke",
                                                    .from(["name": tool,
                                                           "args": ["path": path]])),
               let text = res["output"]?.stringValue ?? res["content"]?.stringValue,
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    // MARK: Write

    @discardableResult
    func write(_ path: String, content: String) async -> WriteMethod {
        let id = await resolveAgentId() ?? "main"

        // Reuse whatever worked last time.
        if let known = writeMethod, known != .unavailable,
           await attempt(known, id: id, path: path, content: content) {
            return known
        }

        for method in [WriteMethod.filesName, .filesFile, .filesPath,
                       .filesArray, .toolInvoke, .agentAssisted] {
            if await attempt(method, id: id, path: path, content: content) {
                writeMethod = method
                NSLog("[workspace] write via %@", method.rawValue)
                return method
            }
        }
        writeMethod = .unavailable
        return .unavailable
    }

    private func attempt(_ method: WriteMethod, id: String,
                         path: String, content: String) async -> Bool {
        switch method {
        case .filesName:
            return await rpcOK("agents.files.set",
                               .from(["agentId": id, "name": path, "content": content]))
        case .filesFile:
            return await rpcOK("agents.files.set",
                               .from(["agentId": id, "file": path, "content": content]))
        case .filesPath:
            return await rpcOK("agents.files.set",
                               .from(["agentId": id, "path": path, "content": content]))
        case .filesArray:
            return await rpcOK("agents.files.set", .object([
                "agentId": .string(id),
                "files": .array([.object(["name": .string(path),
                                          "content": .string(content)])]),
            ]))
        case .toolInvoke:
            for tool in ["write_file", "fs_write", "file_write"] {
                if await rpcOK("tools.invoke",
                               .from(["name": tool,
                                      "args": ["path": path, "content": content]])) {
                    return true
                }
            }
            return false
        case .agentAssisted:
            // Last resort: the agent has file tools — ask it directly, in a
            // side session so the main transcript stays clean.
            return await rpcOK("chat.send", .from([
                "sessionKey": Self.sessionKey,
                "message": """
                    [athena-file-write] Write this file to your workspace exactly \
                    as given, creating any parent directories. Reply only "ok".

                    Path: \(path)

                    <<<CONTENT
                    \(content)
                    CONTENT

                    """,
                "idempotencyKey": UUID().uuidString,
            ]))
        case .unavailable:
            return false
        }
    }

    private func rpcOK(_ method: String, _ params: JSONValue) async -> Bool {
        do { _ = try await gateway.request(method, params); return true }
        catch { return false }
    }
}
