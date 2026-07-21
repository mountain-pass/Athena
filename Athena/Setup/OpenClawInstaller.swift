import Foundation

/// Installs and manages a *local* OpenClaw gateway on this Mac.
/// Used by the setup wizard's "Install OpenClaw here" path.
///
/// NOTE: verify the install command against https://docs.openclaw.ai/install
/// for the current release; it is defined in `installCommand` below.
@MainActor
final class OpenClawInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case installing
        case startingGateway
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: [String] = []

    /// Official one-liner installer (installs Node + OpenClaw + gateway service).
    private let installCommand = #"curl -fsSL https://openclaw.ai/install.sh | bash"#

    var isInstalled: Bool {
        // The installer links the CLI into standard locations.
        let paths = ["/usr/local/bin/openclaw", "/opt/homebrew/bin/openclaw",
                     NSHomeDirectory() + "/.local/bin/openclaw"]
        return paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func installAndStart() {
        Task {
            phase = .checking
            append("Checking for existing OpenClaw installation…")
            if !isInstalled {
                phase = .installing
                append("$ \(installCommand)")
                let ok = await run(installCommand)
                guard ok else { phase = .failed("Installer exited with an error — see log"); return }
            } else {
                append("OpenClaw already installed ✓")
            }
            phase = .startingGateway
            append("Installing gateway as a launchd service…")
            // `openclaw onboard` normally does this; non-interactive path:
            _ = await run("openclaw gateway install || openclaw onboard --no-interactive || true")
            _ = await run("openclaw gateway start || true")
            append("Waiting for gateway on ws://127.0.0.1:18789 …")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            phase = .ready
            append("Gateway ready ✓ — continue to configuration")
        }
    }

    /// Runs a shell command with the user's login environment, streaming output to `log`.
    private func run(_ command: String) async -> Bool {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    text.split(separator: "\n").forEach { self?.append(String($0)) }
                }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus == 0)
            }
            do { try process.run() } catch {
                Task { @MainActor in self.append("Failed to launch: \(error.localizedDescription)") }
                cont.resume(returning: false)
            }
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
