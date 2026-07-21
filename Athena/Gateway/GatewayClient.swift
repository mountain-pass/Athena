import Foundation
import Combine

struct GatewayEvent {
    let name: String
    let payload: JSONValue
}

struct ConnectionSettings: Codable, Equatable {
    /// e.g. ws://127.0.0.1:18789 (local) or ws://macmini.tailnet-name.ts.net:18789
    var urlString: String = "ws://127.0.0.1:18789"
    var token: String = ""

    var url: URL? { URL(string: urlString) }

    static func load() -> ConnectionSettings {
        var s = ConnectionSettings()
        s.urlString = UserDefaults.standard.string(forKey: "gateway.url") ?? s.urlString
        s.token = Keychain.readString(service: "com.athena.gateway", account: "token") ?? ""
        return s
    }
    func save() {
        UserDefaults.standard.set(urlString, forKey: "gateway.url")
        Keychain.writeString(service: "com.athena.gateway", account: "token", token)
    }
}

/// WebSocket client for the OpenClaw Gateway protocol (v3).
/// Framing: {type:"req"|"res"|"event", ...} — see docs.openclaw.ai/gateway/protocol
@MainActor
final class GatewayClient: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(serverVersion: String)
        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var helloSnapshot: JSONValue = .null

    // Handshake diagnostics — surfaced when a connection stalls.
    private var framesReceived = 0
    private var challengeSeen = false
    private var connectSent = false

    /// All gateway events (chat, heartbeat, cron, presence, tick, …).
    let events = PassthroughSubject<GatewayEvent, Never>()

    private var settings = ConnectionSettings.load()
    private var socket: URLSessionWebSocketTask?
    private var session = URLSession(configuration: .default)
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var reconnectAttempt = 0
    private var wantConnected = false
    private var receiveLoopTask: Task<Void, Never>?
    private let identity = DeviceIdentity.loadOrCreate()
    private var deviceToken: String? {
        get { Keychain.readString(service: "com.athena.gateway", account: "deviceToken") }
        set {
            if let v = newValue { Keychain.writeString(service: "com.athena.gateway", account: "deviceToken", v) }
            else { Keychain.delete(service: "com.athena.gateway", account: "deviceToken") }
        }
    }

    struct GatewayError: LocalizedError {
        let message: String
        var code: String? = nil
        var details: JSONValue = .null
        var errorDescription: String? { message }
        /// True when the failure was just "we're offline" — callers can skip
        /// their error UI and simply retry later.
        var isOffline: Bool { code == "OFFLINE" }
    }

    /// Non-nil while the gateway is waiting for this device to be approved.
    /// UI should show pairing instructions; reconnect keeps retrying so the
    /// app connects automatically once approval happens.
    @Published private(set) var pairingInstructions: String?

    // MARK: Lifecycle

    func connect(_ newSettings: ConnectionSettings? = nil) {
        if let s = newSettings { settings = s; settings.save() }
        guard let url = settings.url else {
            lastError = "Invalid gateway URL"; return
        }
        wantConnected = true
        state = .connecting
        lastError = nil
        NSLog("[gateway] connect() CLIENT BUILD v3-deadlockfix → %@", url.absoluteString)

        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 26_214_400 // 25 MB, matches gateway maxPayload
        socket = task
        framesReceived = 0
        challengeSeen = false
        connectSent = false
        task.resume()

        receiveLoopTask?.cancel()
        receiveLoopTask = Task { await receiveLoop(task) }

        // Fallback: some builds/paths may not push `connect.challenge` first.
        // If the socket is open but silent after 3s, send connect anyway.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.socket === task, self.state == .connecting,
                  !self.challengeSeen, !self.connectSent else { return }
            NSLog("[gateway] no challenge after 3s — sending connect without nonce")
            await self.sendConnect(nonce: "")
        }
        // Hard timeout: report exactly how far the handshake got.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.socket === task, self.state == .connecting else { return }
            let stage = self.framesReceived == 0
                ? "socket opened but server sent nothing"
                : "received \(self.framesReceived) frame(s), challenge=\(self.challengeSeen), connectSent=\(self.connectSent), no hello-ok"
            self.lastError = "Handshake stalled: \(stage). Check URL path/port (Serve = wss://host, port 443; direct = ws://host:18789) and that the gateway is running."
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    func disconnect() {
        wantConnected = false
        receiveLoopTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        failAllPending("Disconnected")
        state = .disconnected
    }

    // MARK: RPC

    func request(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        guard let socket else { throw GatewayError(message: "Not connected", code: "OFFLINE") }
        // Fail fast while offline. Without this, every poller queues 30s
        // timeouts against a dead socket and they all pile up on reconnect.
        if !state.isConnected, method != "connect" {
            throw GatewayError(message: "Gateway offline", code: "OFFLINE")
        }
        let id = UUID().uuidString
        // NOTE: no blanket idempotencyKey injection — several methods
        // (cron.add among them) have strict schemas that reject unknown
        // properties. Methods that support it (chat.send) set it explicitly.
        let frame: [String: JSONValue] = [
            "type": .string("req"),
            "id": .string(id),
            "method": .string(method),
            "params": params,
        ]
        // Serialize off-main: encoding a frame carrying a base64 attachment
        // is expensive and must not block the UI.
        let frameValue = JSONValue.object(frame)
        let data: String
        if method == "chat.send" {
            data = await Task.detached(priority: .userInitiated) { frameValue.jsonString }.value
        } else {
            data = frameValue.jsonString
        }

        // Per-RPC timeout (30s, matches the reference client).
        // `pending.removeValue` is the single point of ownership: whoever
        // removes the continuation resumes it. Resuming twice is a fatal
        // error in Swift, so nothing else may touch it.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let cont = self?.pending.removeValue(forKey: id) else { return }
            cont.resume(throwing: GatewayError(message: "\(method) timed out after 30s"))
        }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            socket.send(.string(data)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let pendingCont = self?.pending.removeValue(forKey: id) else { return }
                    pendingCont.resume(throwing: error)
                }
            }
        }
    }


    // MARK: Receive loop

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: text = ""
                }
                await handleFrame(text)
            } catch {
                await handleDisconnect(error)
                return
            }
        }
    }

    private func handleFrame(_ text: String) async {
        framesReceived += 1
        NSLog("[gateway] ← %@", String(text.prefix(400)))
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return }
        switch value["type"]?.stringValue {
        case "event":
            let name = value["event"]?.stringValue ?? ""
            let payload = value["payload"] ?? .null
            if name == "connect.challenge" {
                challengeSeen = true
                guard !connectSent else { return }
                // MUST NOT await here: sendConnect waits for the gateway's
                // response, which this receive loop has to stay free to read.
                let nonce = payload["nonce"]?.stringValue ?? ""
                Task { await self.sendConnect(nonce: nonce) }
            } else {
                events.send(GatewayEvent(name: name, payload: payload))
            }
        case "res":
            guard let id = value["id"]?.stringValue,
                  let cont = pending.removeValue(forKey: id) else { return }
            if value["ok"]?.boolValue == true {
                cont.resume(returning: value["payload"] ?? .null)
            } else {
                // Surface the full failure: message + details.code + recovery hint,
                // e.g. "device pairing required [DEVICE_PAIRING_PENDING] → approve on gateway"
                let err = value["error"]
                let code = err?["details"]?["code"]?.stringValue ?? err?["code"]?.stringValue
                var msg = err?["message"]?.stringValue ?? "Gateway error"
                if let code { msg += " [\(code)]" }
                if let reason = err?["details"]?["reason"]?.stringValue { msg += " (\(reason))" }
                if let next = err?["details"]?["recommendedNextStep"]?.stringValue { msg += " → \(next)" }
                cont.resume(throwing: GatewayError(message: msg, code: code,
                                                   details: err?["details"] ?? .null))
            }
        default:
            break
        }
    }

    // MARK: Handshake

    /// Gateway schema restricts client.id/client.mode to fixed enums.
    /// "cli" is the reference operator client. If your gateway version rejects
    /// these, grep its dist for the allowed literals (see README).
    static let wireClientID = "cli"
    static let wireClientMode = "cli"

    private func sendConnect(nonce: String) async {
        connectSent = true
        let role = "operator"
        // Matches the Control UI's default operator scope set.
        let scopes = ["operator.admin", "operator.read", "operator.write",
                      "operator.approvals", "operator.pairing"]
        let clientID = Self.wireClientID
        let mode = Self.wireClientMode
        let signedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let authToken = deviceToken ?? settings.token

        let params: JSONValue = .from([
            // Your 2026.7.1 gateway speaks protocol 4 (Control UI sends 4/4).
            "minProtocol": 3,
            "maxProtocol": 4,
            "client": [
                "id": clientID,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
                "platform": "macos",
                "mode": mode,
            ],
            "role": role,
            "scopes": scopes,
            "caps": [], "commands": [], "permissions": [:],
            "auth": ["token": authToken],
            "locale": "en-US",
            "userAgent": "athena-macos/0.1.0",
            "device": [
                "id": identity.deviceID,
                "publicKey": identity.publicKeyBase64,
                "signature": identity.signature(clientID: clientID, mode: mode, role: role,
                                                scopes: scopes, token: authToken,
                                                nonce: nonce, signedAt: signedAt),
                "signedAt": signedAt,
                "nonce": nonce,
            ],
        ])

        do {
            NSLog("[gateway] → connect req (nonce=%@, deviceId=%@…)", nonce, String(identity.deviceID.prefix(12)))
            let hello = try await request("connect", params)
            let version = hello["server"]?["version"]?.stringValue ?? "?"
            if let dt = hello["auth"]?["deviceToken"]?.stringValue { deviceToken = dt }
            helloSnapshot = hello["snapshot"] ?? .null
            reconnectAttempt = 0
            pairingInstructions = nil
            state = .connected(serverVersion: version)
            events.send(GatewayEvent(name: "athena.connected", payload: hello))
        } catch {
            // Self-heal: a stale stored device token causes endless auth
            // failures on relaunch. Drop it and retry with the shared token.
            if let ge = error as? GatewayError, let code = ge.code,
               code.hasPrefix("AUTH_") || code.hasPrefix("DEVICE_AUTH_"),
               deviceToken != nil {
                NSLog("[gateway] clearing stored device token after %@ — retrying with shared token", code)
                deviceToken = nil
            }
            if let ge = error as? GatewayError, ge.code == "PAIRING_REQUIRED" {
                let requestId = ge.details["requestId"]?.stringValue
                let reason = ge.details["reason"]?.stringValue ?? "not-paired"
                var lines = [
                    "This device needs approval on your gateway (\(reason)).",
                    "On the gateway machine, either:",
                    "  • Dashboard → Devices → approve the pending request",
                    "  • Terminal:  openclaw devices  (list pending)",
                    "               openclaw devices approve \(requestId ?? "<request-id>")",
                    "Athena keeps retrying and will connect automatically once approved.",
                ]
                if let hint = ge.details["remediationHint"]?.stringValue { lines.insert(hint, at: 1) }
                pairingInstructions = lines.joined(separator: "\n")
            }
            lastError = error.localizedDescription
            socket?.cancel(with: .normalClosure, reason: nil)
        }
    }

    // MARK: Reconnect

    private func handleDisconnect(_ error: Error) async {
        failAllPending(error.localizedDescription)
        guard wantConnected else { state = .disconnected; return }
        state = .disconnected
        // Network-level drops (VPN toggling, sleep, Wi-Fi switch) are routine —
        // report them plainly rather than as an error the user must act on.
        let nsError = error as NSError
        let transient = [NSURLErrorNetworkConnectionLost,
                         NSURLErrorNotConnectedToInternet,
                         NSURLErrorTimedOut,
                         NSURLErrorCannotConnectToHost,
                         NSURLErrorDNSLookupFailed,
                         57, 54].contains(nsError.code)
        lastError = transient
            ? "Connection lost — reconnecting…"
            : error.localizedDescription
        events.send(GatewayEvent(name: "athena.disconnected",
                                 payload: .from(["transient": transient])))
        reconnectAttempt += 1
        // Exponential backoff: 1s … 30s (matches the reference client).
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        events.send(GatewayEvent(name: "athena.reconnecting",
                                 payload: .from(["attempt": reconnectAttempt, "delaySec": delay])))
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        if wantConnected { connect() }
    }

    private func failAllPending(_ message: String) {
        for (_, cont) in pending { cont.resume(throwing: GatewayError(message: message)) }
        pending.removeAll()
    }
}
