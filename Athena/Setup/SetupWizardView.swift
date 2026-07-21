import SwiftUI

/// First-run experience (Bailongma-style "activation page", in English).
///
/// Two paths:
/// 1. **Connect to existing OpenClaw** — enter the gateway address (Tailscale
///    hostname of your Mac Mini) + token, test, done.
/// 2. **Install OpenClaw on this Mac** — runs the official installer, starts
///    the gateway locally, then drives OpenClaw's onboarding *wizard over RPC*
///    so the whole CLI setup happens inside this native UI.
struct SetupWizardView: View {
    enum Step { case welcome, connectRemote, installLocal, onboarding, models, done }

    @EnvironmentObject var app: AppState
    @EnvironmentObject var gateway: GatewayClient
    @StateObject private var installer = OpenClawInstaller()
    @State private var step: Step = .welcome
    @State private var urlString = "ws://"
    @State private var token = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("GET STARTED / ACTIVATION")
                    .font(Theme.label).kerning(2).foregroundStyle(Theme.amber)
                Text("Athena Setup").font(Theme.mono(26, weight: .bold)).foregroundStyle(Theme.text)
            }
            .padding(.top, 40)

            Group {
                switch step {
                case .welcome: welcome
                case .connectRemote: connectRemote
                case .installLocal: installLocal
                case .onboarding: OnboardingWizardView(onFinished: { step = .models })
                case .models: ModelSetupStep(onContinue: finish)
                case .done: doneView
                }
            }
            .frame(maxWidth: 560)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: Step 1 — choose a path

    private var welcome: some View {
        VStack(spacing: 14) {
            ChoiceCard(
                icon: "antenna.radiowaves.left.and.right",
                title: "Connect to existing OpenClaw",
                subtitle: "Your gateway already runs elsewhere (e.g. a Mac Mini reached over Tailscale). Enter its address and token."
            ) { step = .connectRemote }

            ChoiceCard(
                icon: "arrow.down.circle",
                title: "Install OpenClaw on this Mac",
                subtitle: "Fresh install: Athena downloads OpenClaw, starts the gateway, and walks you through configuration — no terminal needed."
            ) { step = .installLocal }
        }
    }

    // MARK: Step 2a — connect to remote gateway

    private var connectRemote: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Part 01 / Gateway Address")
            TextField("ws://macmini.your-tailnet.ts.net:18789", text: $urlString)
                .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.text)
                .padding(10).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            Text("Tip: with Tailscale on both machines, use your Mac Mini's tailnet hostname. On the same LAN, its local IP works too (ws://192.168.x.x:18789).")
                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)

            SectionLabel(text: "Part 02 / Gateway Token")
            SecureField("gateway auth token", text: $token)
                .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.text)
                .padding(10).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            Text("On the gateway machine: openclaw config get gateway.auth.token")
                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)

            if let pairing = gateway.pairingInstructions {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        SectionLabel(text: "Pairing Approval Needed", color: Theme.amber)
                    }
                    Text(pairing)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.amber.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.amber.opacity(0.4)))
            } else if let result = testResult {
                Text(result).font(Theme.mono(11))
                    .foregroundStyle(result.hasPrefix("✓") ? Theme.green : Theme.red)
            }

            HStack {
                Button("Back") { step = .welcome }.buttonStyle(.plain)
                    .font(Theme.body).foregroundStyle(Theme.textDim)
                Spacer()
                Button(testing ? "Connecting…" : "Activate & Enter") { testAndFinish() }
                    .buttonStyle(.plain)
                    .font(Theme.mono(13, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Theme.amber).clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.black)
                    .disabled(testing || urlString.count < 8)
            }
        }
    }

    private func testAndFinish() {
        testing = true
        testResult = nil
        var settings = ConnectionSettings()
        settings.urlString = urlString
        settings.token = token
        gateway.connect(settings)
        Task {
            // Poll ~20s normally; while pairing approval is pending, keep
            // waiting up to 3 minutes — reconnect picks up the approval.
            var ticks = 0
            while ticks < 80 || (gateway.pairingInstructions != nil && ticks < 720) {
                ticks += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
                if case .connected(let v) = gateway.state {
                    testResult = "✓ Connected — gateway v\(v)"
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    finish()
                    testing = false
                    return
                }
                if gateway.pairingInstructions == nil, let err = gateway.lastError {
                    testResult = "✗ \(err)"
                }
            }
            if testResult == nil { testResult = "✗ Could not reach gateway (check address, token, Tailscale)" }
            testing = false
        }
    }

    // MARK: Step 2b — local install

    private var installLocal: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Installing OpenClaw locally")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(installer.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(height: 260)
                .background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: installer.log.count) { _, _ in proxy.scrollTo("bottom") }
            }

            HStack {
                Button("Back") { step = .welcome }.buttonStyle(.plain)
                    .font(Theme.body).foregroundStyle(Theme.textDim)
                Spacer()
                switch installer.phase {
                case .idle:
                    Button("Begin Install") { installer.installAndStart() }
                        .buttonStyle(.plain).font(Theme.mono(13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Theme.amber).clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.black)
                case .ready:
                    Button("Continue → Configure") {
                        var s = ConnectionSettings()
                        s.urlString = "ws://127.0.0.1:18789"
                        gateway.connect(s)
                        step = .onboarding
                    }
                    .buttonStyle(.plain).font(Theme.mono(13, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Theme.green).clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.black)
                case .failed(let reason):
                    Text(reason).font(Theme.mono(11)).foregroundStyle(Theme.red)
                default:
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Theme.green)
            Text("Athena is online.").font(Theme.title).foregroundStyle(Theme.text)
        }
    }

    private func finish() {
        var settings = ConnectionSettings.load()
        if step == .connectRemote || urlString.count > 8 {
            settings.urlString = step == .installLocal || step == .onboarding
                ? "ws://127.0.0.1:18789" : urlString
            settings.token = token
        }
        step = .done
        app.completeSetup(with: settings)
    }
}

// MARK: Reusable choice card

struct ChoiceCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Theme.amber)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.mono(14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.textFaint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
        .buttonStyle(.plain)
    }
}

// MARK: Native onboarding over `wizard.*` RPC

/// Renders OpenClaw's onboarding wizard steps natively. The gateway drives the
/// flow (`wizard.start` / `wizard.next`); we render whatever prompt/options the
/// current step describes — so CLI setup (model provider, API keys, channels)
/// happens in this UI instead of a terminal.
struct OnboardingWizardView: View {
    @EnvironmentObject var gateway: GatewayClient
    let onFinished: () -> Void

    @State private var current: JSONValue = .null
    @State private var textAnswer = ""
    @State private var error: String?
    @State private var finishedRemotely = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "OpenClaw Configuration")

            if current == .null {
                ProgressView("Starting configuration wizard…").font(Theme.body)
            } else {
                Text(prompt).font(Theme.body).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)

                if let options = current["options"]?.arrayValue ?? current["step"]?["options"]?.arrayValue {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                        let label = opt["label"]?.stringValue ?? opt.stringValue ?? "Option"
                        let value = opt["value"] ?? opt
                        Button(label) { submit(value) }
                            .buttonStyle(.plain).font(Theme.body).foregroundStyle(Theme.amber)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    TextField("Answer…", text: $textAnswer)
                        .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.text)
                        .padding(10).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                        .onSubmit { submit(.string(textAnswer)) }
                    Button("Next") { submit(.string(textAnswer)) }
                        .buttonStyle(.plain).font(Theme.mono(13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Theme.amber).clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.black)
                }
            }

            if let error { Text(error).font(Theme.mono(11)).foregroundStyle(Theme.red) }

            HStack {
                Spacer()
                Button("Skip — finish setup") { onFinished() }
                    .buttonStyle(.plain).font(Theme.mono(11)).foregroundStyle(Theme.textDim)
            }
        }
        .task { await start() }
    }

    private var prompt: String {
        current["prompt"]?.stringValue
            ?? current["question"]?.stringValue
            ?? current["step"]?["prompt"]?.stringValue
            ?? current["title"]?.stringValue
            ?? "Continue configuration"
    }

    private func start() async {
        do { current = try await gateway.wizardStart() }
        catch { self.error = error.localizedDescription }
    }

    private func submit(_ answer: JSONValue) {
        Task {
            do {
                let next = try await gateway.wizardNext(answer: answer)
                textAnswer = ""
                if next["done"]?.boolValue == true || next["status"]?.stringValue == "complete" {
                    onFinished()
                } else {
                    current = next
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
