# Athena

A native macOS client for [OpenClaw](https://openclaw.ai) — a Jarvis-style AI agent with push-to-talk voice, a live "cognition" dashboard, a geo-mapped news monitor, and scheduled automation.

The agent itself (memory, tools, heartbeat, cron) runs on an OpenClaw Gateway — on this Mac or on an always-on machine like a Mac Mini reached over Tailscale. Athena is a thin, stateful-free client: close the lid, move networks, reopen — the agent never stopped.

> Inspired by the [Bailongma](https://bailongma.top) interface, rebuilt natively in SwiftUI, in English.

---

## Features

**Chat** — streaming responses, image/video/audio/file attachments, full session history synced from the gateway.

**Voice** — hold `SPACE` anywhere to talk (on-device transcription via `SFSpeechRecognizer`), release to send, spoken reply. Typed messages get typed replies. Three TTS engines:

| Engine | Runs where | Notes |
|---|---|---|
| System | Local | macOS voices; download a *Premium* voice for a big quality jump |
| Kokoro | Local, embedded | Kokoro-82M on Apple Silicon — offline, no server, no Docker |
| Server | Remote | Any OpenAI-compatible `/v1/audio/speech` (kokoro-fastapi, CosyVoice) |

**Live cognition dashboard** — a particle sphere that reacts to real microphone and speech amplitude, a heartbeat ECG that spikes on each agent wake, an action log, a thinking/tool feed, and a stats strip (status, tokens/sec, tokens, messages, ticks).

**News monitor** — a rotating dotted globe with pulsing targets where your stories are happening. Headlines are geo-tagged locally by keyword (no API, no tokens); click a target to see that region's stories. Topic columns flank the globe; RSS/Atom feeds are fetched natively. Add, rename, and delete topics and sources behind the gear. A daily AI brief can be scheduled on the gateway.

**Jobs** — full cron manager for gateway automations: create, edit, enable, run-now, delete. Jobs run on the gateway, so they fire while this Mac sleeps.

---

## Architecture

```
┌─ MacBook — Athena.app ──────────┐        ┌─ Mac Mini (24/7) ───────────┐
│  SwiftUI UI                     │        │  OpenClaw Gateway (launchd) │
│  • Chat, News, Jobs             │  WS    │  • Sessions + memory        │
│  • Voice: local STT/TTS         │◄──────►│  • Tools, skills            │
│  • Globe, orb, dashboards       │        │  • Heartbeat (self-wake)    │
│  • No agent state               │        │  • Cron (daily brief)       │
└─────────────────────────────────┘        └─────────────────────────────┘
              └── Tailscale (wss://mini.tailnet.ts.net) ──┘
```

All state lives on the gateway. Athena reconnects with exponential backoff, re-syncs history, and self-heals stale device tokens.

### Project layout

```
Athena/
├── App/          AthenaApp, AppState, MainView, Theme
├── Gateway/      WebSocket client, protocol v4, device identity, RPC wrappers
├── Chat/         ChatStore (streaming + history), ChatView
├── Voice/        VoiceManager (STT/TTS), KokoroEngine, ParticleSphereView, FileDownloader
├── News/         NewsStore, RSSFeed parser, GeoTagger, WorldGlobe, NewsView
├── Jobs/         JobsStore, JobsView (cron)
├── Panels/       ActivityStore, dashboard panels
├── Setup/        First-run wizard, OpenClaw installer
└── Settings/     Connection + voice settings
```

---

## Getting started

### Requirements

- macOS 14+, Apple Silicon (M1+) for embedded Kokoro
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A running [OpenClaw](https://docs.openclaw.ai/install) gateway (Athena can install one for you)

### Build

```bash
git clone <your-repo-url> Athena && cd Athena
./Scripts/fetch-kokoro.sh     # optional: vendors the embedded TTS package
xcodegen
open Athena.xcodeproj         # set your signing team, then ⌘R
```

Or build and launch without Xcode:

```bash
./Scripts/run.sh              # build + run
./Scripts/run.sh --watch      # rebuild + relaunch on save (needs fswatch)
```

### First run

The setup wizard offers two paths:

1. **Connect to existing OpenClaw** — enter the gateway URL and token.
   Get the token on the gateway machine: `openclaw config get gateway.auth.token`
2. **Install OpenClaw on this Mac** — runs the official installer, starts the gateway, then drives OpenClaw's onboarding wizard natively over RPC (no terminal).

The first remote connection needs one-time device approval on the gateway
(`openclaw devices`, or the Control UI). Athena shows the instructions and
connects automatically once approved.

---

## Remote gateway setup (recommended)

Run the agent on a machine that's always on; connect from anywhere over Tailscale.

**On the gateway machine:**

```bash
# Install OpenClaw + set a token
openclaw config set gateway.auth.token "$(openssl rand -hex 32)"

# Option A — Tailscale Serve (HTTPS, also gives you the web dashboard)
openclaw config set gateway.bind loopback
tailscale serve --bg --https=443 http://127.0.0.1:18789
#   → Athena URL:  wss://<machine>.<tailnet>.ts.net     (no port)

# Option B — direct tailnet bind (simplest, no proxy)
openclaw config set gateway.bind tailnet
#   → Athena URL:  ws://100.x.y.z:18789
```

Then disable sleep on that machine (System Settings → Energy / `caffeinate`).

> **Never** port-forward 18789 to the public internet, and don't use Tailscale
> **Funnel** for the gateway — it exposes the agent (which has shell access) to
> the world. Serve is tailnet-only; that's what you want.

**Scheme and port must match:**

| Setup | URL |
|---|---|
| Tailscale Serve | `wss://host.tailnet.ts.net` — no port |
| Direct tailnet bind | `ws://100.x.y.z:18789` |
| Local | `ws://127.0.0.1:18789` |

`wss://host:18789` fails — 18789 speaks plaintext.

---

## Troubleshooting

Hard-won notes from getting this talking to a real gateway.

**`-1022 App Transport Security` / "requires a secure connection"**
macOS blocks plaintext `ws://` to non-localhost. `Info.plist` sets
`NSAllowsArbitraryLoads` (safe here — Tailscale already encrypts end-to-end).
Note a `ts.net` exception domain does **not** work: `ts.net` is on the Public
Suffix List, so ATS ignores it. After changing the plist, clean the build
folder (⇧⌘K) — Xcode caches it.

**`-1004 Could not connect`** — nothing is listening on that address. The
gateway binds to loopback by default: `lsof -iTCP:18789 -sTCP:LISTEN`. Use
`gateway.bind tailnet` or Tailscale Serve.

**`-1011 bad response` / HTTP 502 through Serve** — the proxy mapping is
wrong. `tailscale serve status` should show `https:443 → http://127.0.0.1:18789`.
A stale Funnel config is a common culprit: `tailscale funnel reset && tailscale serve reset`,
then re-add. Note OpenClaw can manage Serve itself (`gateway.tailscale.mode`) —
pick one owner, not both.

**Handshake stalls after `connect.challenge`** — the client must not block its
receive loop while awaiting the connect response (this bit us; see
`GatewayClient.handleFrame`).

**`INVALID_REQUEST: invalid connect params`** — schema mismatch. Notably:
`client.id`/`client.mode` are enums (`cli`, `gateway-client`, `openclaw-macos`…),
`signedAt` must serialize as an integer (not `1.7e12`), and this gateway
speaks **protocol 4**.

**`DEVICE_AUTH_SIGNATURE_INVALID`** — the v2 signature payload is
`v2|deviceId|clientId|clientMode|role|scopes,csv|signedAtMs|token|nonce`.
Verified against the Control UI's own client (`dist/control-ui/assets/gateway-*.js`);
re-check there if a future release changes it.

**`PAIRING_REQUIRED`** — approve the device on the gateway. Athena keeps
retrying and connects itself once approved. Requesting broader scopes triggers a
fresh approval.

**Token works in the browser but not the probe** — `openclaw gateway probe --url`
never uses config credentials; pass `--token` explicitly.

**Kokoro download fails** — it resumes and retries automatically; if it still
fails, install manually (below).

### Kokoro manual install

```bash
mkdir -p ~/Library/Application\ Support/Athena/Kokoro
cd ~/Library/Application\ Support/Athena/Kokoro
BASE=https://huggingface.co/mweinbach/Kokoro-82M-Swift/resolve/main/MLX_GPU
curl -L -C - -o config.json "$BASE/config.json"
curl -L -C - -o kokoro-v1_0.safetensors "$BASE/kokoro-v1_0.safetensors"   # ~330MB
```

`-C -` resumes; rerun if it drops. Then Settings → Voice → Kokoro → **Load model**.

---

## Development

- **Code-only changes:** just ⌘R. `xcodegen` is only needed when files are
  added/removed or `project.yml` changes.
- **Skip xcodegen entirely (Xcode 16+):** replace the `Athena` group with a
  synchronized/buildable folder, commit `Athena.xcodeproj`, drop `project.yml`.
- **UI iteration:** SwiftUI Previews render without launching the app or
  reconnecting to the gateway.
- **Gateway debugging:** every frame is logged as `[gateway] ←` / `→` in the
  Xcode console.

---

## Roadmap

- [ ] Menu-bar mini mode + global hotkey
- [ ] Wake word ("Hey Athena") via `voicewake.*` RPC
- [ ] Native dialogs for exec-approval requests
- [ ] Real token accounting from the gateway's `usage.*` RPCs
- [ ] Notifications when the daily brief lands
- [ ] Streaming token-by-token rendering (currently history-refresh based)
- [ ] Richer globe: arcs between related stories, day/night terminator

---

## Credits

- [OpenClaw](https://openclaw.ai) — agent runtime and gateway (the actual brains)
- [Bailongma](https://bailongma.top) — interface inspiration
- [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) by hexgrad, via
  [kokoro-swift](https://github.com/mweinbach/kokoro-swift) — embedded TTS
- Apple: SwiftUI, Speech, AVFoundation, MLX

## License

MIT — see [LICENSE](LICENSE).
