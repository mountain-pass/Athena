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

    /// `agents.files.*` only manages a fixed set of bootstrap files — anything
    /// else comes back as `unsupported file "…"`. Discovered once via
    /// `agents.files.list`, with a sensible default until then.
    private(set) var allowedNames: Set<String> = ["AGENTS.md", "HEARTBEAT.md"]
    private var listedFiles = false

    /// True when this path can go through the files RPC at all.
    func isBootstrapFile(_ path: String) async -> Bool {
        await listFiles()
        return allowedNames.contains(path)
    }

    private func listFiles() async {
        guard !listedFiles else { return }
        listedFiles = true
        let id = await resolveAgentId() ?? "main"
        guard let res = try? await gateway.request("agents.files.list",
                                                   .from(["agentId": id])) else { return }
        var names: Set<String> = []
        let rows = res["files"]?.arrayValue ?? res.arrayValue ?? []
        for row in rows {
            if let name = row["name"]?.stringValue ?? row.stringValue { names.insert(name) }
        }
        if !names.isEmpty {
            allowedNames = names
            NSLog("[workspace] bootstrap files: %@", names.sorted().joined(separator: ", "))
        }
    }

    private let gateway: GatewayClient
    private(set) var agentId: String?
    private(set) var writeMethod: WriteMethod?
    /// Real tool names, discovered from the gateway rather than guessed.
    private(set) var writeTool: String?
    private(set) var readTool: String?
    private var toolsDiscovered = false
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

    // MARK: Tool discovery
    //
    // Guessing names ("write_file", "fs_write"…) produced a stream of
    // "Tool not available" errors. Ask the gateway what it actually has.

    func discoverTools() async {
        guard !toolsDiscovered else { return }
        toolsDiscovered = true

        let id = await resolveAgentId() ?? "main"
        var catalog: JSONValue?
        if let res = try? await gateway.request("tools.catalog", .from(["agentId": id])) {
            catalog = res
        } else if let res = try? await gateway.request("tools.catalog") {
            catalog = res
        }
        guard let res = catalog else { return }

        // The catalog nests tools under groups on some versions.
        var names: [String] = []
        // Bounded recursion — a malformed/cyclic payload must not hang or
        // blow the stack.
        func collect(_ value: JSONValue, depth: Int = 0) {
            guard depth < 6, names.count < 500 else { return }
            if let name = value["name"]?.stringValue { names.append(name) }
            if let array = value.arrayValue {
                for element in array.prefix(300) { collect(element, depth: depth + 1) }
            }
            if let object = value.objectValue {
                for element in object.values.prefix(60) { collect(element, depth: depth + 1) }
            }
        }
        collect(res)

        let lower = names.map { ($0, $0.lowercased()) }
        // Prefer explicit file tools, then anything that writes/reads.
        writeTool = lower.first { $0.1.contains("write") && ($0.1.contains("file") || $0.1.contains("fs")) }?.0
            ?? lower.first { $0.1.contains("write") }?.0
            ?? lower.first { $0.1 == "edit" || $0.1.contains("create_file") }?.0
        readTool = lower.first { $0.1.contains("read") && ($0.1.contains("file") || $0.1.contains("fs")) }?.0
            ?? lower.first { $0.1.contains("read") }?.0
            ?? lower.first { $0.1 == "cat" }?.0

        NSLog("[workspace] %d tools; write=%@ read=%@", names.count,
              writeTool ?? "none", readTool ?? "none")
    }

    // MARK: Read

    /// Remembered read shape, so we stop re-probing (and spamming errors).
    private enum ReadShape: String { case name, file, path, bare }
    private var readShape: ReadShape?

    func read(_ path: String) async -> String? {
        guard gateway.state.isConnected else { return nil }
        let id = await resolveAgentId() ?? "main"

        // Bootstrap files use the documented {agentId, name} shape. Anything
        // else is rejected outright — don't waste round-trips on it.
        if await isBootstrapFile(path) {
            if let res = try? await gateway.request("agents.files.get",
                                                    .from(["agentId": id, "name": path])),
               let text = res["content"]?.stringValue ?? res["text"]?.stringValue
                        ?? res["file"]?["content"]?.stringValue {
                return text
            }
            return nil
        }

        // Arbitrary paths: only a real filesystem tool can reach them.
        await discoverTools()
        if let tool = readTool,
           let res = try? await gateway.request("tools.invoke",
                                                .from(["name": tool, "args": ["path": path]])),
           res["ok"]?.boolValue != false,
           let text = res["output"]?.stringValue ?? res["content"]?.stringValue,
           !text.isEmpty {
            return text
        }
        return nil
    }

    // MARK: Write

    /// Once every method has failed we stop probing for a while — retry storms
    /// on every news fetch / todo edit were flooding the gateway.
    private var unavailableUntil: Date?

    @discardableResult
    func write(_ path: String, content: String) async -> WriteMethod {
        guard gateway.state.isConnected else { return .unavailable }
        if let until = unavailableUntil, Date() < until { return .unavailable }
        let id = await resolveAgentId() ?? "main"

        // Bootstrap files (AGENTS.md, HEARTBEAT.md…) go through the files RPC.
        if await isBootstrapFile(path) {
            if await attempt(.filesName, id: id, path: path, content: content) {
                writeMethod = .filesName
                return .filesName
            }
            NSLog("[workspace] could not write bootstrap file %@", path)
            return .unavailable
        }

        // Everything else needs a filesystem tool; if the gateway exposes
        // none, we simply don't persist there — the app keeps its own copy.
        await discoverTools()
        guard writeTool != nil else {
            unavailableUntil = Date().addingTimeInterval(600)
            NSLog("[workspace] no filesystem tool — %@ stays local-only", path)
            return .unavailable
        }
        if await attempt(.toolInvoke, id: id, path: path, content: content) {
            writeMethod = .toolInvoke
            return .toolInvoke
        }
        unavailableUntil = Date().addingTimeInterval(600)
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
            await discoverTools()
            guard let tool = writeTool else { return false }
            return await rpcOK("tools.invoke",
                               .from(["name": tool,
                                      "args": ["path": path, "content": content]]))
        case .agentAssisted:
            // Last resort: the agent has file tools — ask it directly, in a
            // side session so the main transcript stays clean.
            // Guard against enormous payloads: a multi-MB chat message can
            // stall the gateway and time the client out.
            guard content.utf8.count < 400_000 else {
                NSLog("[workspace] %@ too large for agent-assisted write (%d bytes)",
                      path, content.utf8.count)
                return false
            }
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
        do {
            let payload = try await gateway.request(method, params)
            // tools.invoke returns ok:true at the RPC layer with the real
            // outcome nested in the payload — check that too, or a failure
            // gets cached as "the method that works".
            if payload["ok"]?.boolValue == false {
                let reason = payload["error"]?["message"]?.stringValue ?? "rejected"
                NSLog("[workspace] %@ rejected: %@", method, reason)
                return false
            }
            return true
        } catch {
            return false
        }
    }
}
