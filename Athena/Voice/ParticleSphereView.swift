import SwiftUI

/// Live dotted-sphere animation (Bailongma-style orb).
/// Rotates continuously; audio `level` (0…1) drives radius swell, dot
/// brightness, and jitter — so it visibly reacts to your voice and the
/// assistant's speech.
struct ParticleSphereView: View {
    /// 0…1 live audio amplitude (mic while listening, synth while speaking).
    var level: Float
    var accent: Color = Theme.green

    private static let points: [SIMD3<Float>] = fibonacciSphere(count: 700)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let baseRadius = min(size.width, size.height) * 0.38
                let swell = 1 + CGFloat(level) * 0.22
                let radius = baseRadius * swell
                let rotY = Float(t * 0.35)
                let rotX = Float(sin(t * 0.18) * 0.35)

                for p in Self.points {
                    // Rotate around Y then X.
                    var v = p
                    let cy = cos(rotY), sy = sin(rotY)
                    v = SIMD3(v.x * cy + v.z * sy, v.y, -v.x * sy + v.z * cy)
                    let cx = cos(rotX), sx = sin(rotX)
                    v = SIMD3(v.x, v.y * cx - v.z * sx, v.y * sx + v.z * cx)

                    // Audio jitter along the normal.
                    if level > 0.02 {
                        let n = Self.noise(p, Float(t))
                        v *= 1 + n * level * 0.25
                    }

                    let x = center.x + CGFloat(v.x) * radius
                    let y = center.y + CGFloat(v.y) * radius
                    let depth = (CGFloat(v.z) + 1) / 2 // 0 back … 1 front
                    let dotSize = 0.8 + depth * 1.6
                    let opacity = 0.15 + depth * 0.65 + Double(level) * 0.2

                    context.fill(
                        Path(ellipseIn: CGRect(x: x - dotSize / 2, y: y - dotSize / 2,
                                               width: dotSize, height: dotSize)),
                        with: .color(accent.opacity(min(1, opacity)))
                    )
                }
            }
        }
        .drawingGroup() // Metal-backed
    }

    // MARK: Geometry

    private static func fibonacciSphere(count: Int) -> [SIMD3<Float>] {
        let golden = Float.pi * (3 - sqrt(5.0))
        return (0..<count).map { i in
            let y = 1 - (Float(i) / Float(count - 1)) * 2
            let r = sqrt(max(0, 1 - y * y))
            let theta = golden * Float(i)
            return SIMD3(cos(theta) * r, y, sin(theta) * r)
        }
    }

    /// Cheap deterministic per-point noise.
    private static func noise(_ p: SIMD3<Float>, _ t: Float) -> Float {
        sin(p.x * 12.9898 + p.y * 78.233 + p.z * 37.719 + t * 6) * 0.5 + 0.5
    }
}

/// Orb panel with the "VOICE COMMAND / INPUT READY" chrome around it.
struct VoiceOrbPanel: View {
    @EnvironmentObject var voice: VoiceManager

    private var stateLabel: String {
        switch voice.state {
        case .idle: "INPUT / READY"
        case .listening: "LISTENING"
        case .speaking: "SPEAKING"
        }
    }
    private var accent: Color {
        switch voice.state {
        case .idle: Theme.green
        case .listening: Theme.amber
        case .speaking: Theme.blue
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                StatusDot(on: true, label: "VOICE COMMAND")
                Spacer()
                Text(stateLabel).font(Theme.label).foregroundStyle(accent)
            }
            ParticleSphereView(level: voice.level, accent: accent)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Rectangle())
                .onTapGesture { if voice.isSpeaking { voice.stopSpeaking() } }
                .help(voice.isSpeaking ? "Click to stop speaking" : "")
            if voice.state == .listening {
                // Live transcript grows as you speak — recognition rotates
                // segments underneath, so you can talk for as long as you like.
                ScrollView {
                    Text(voice.liveTranscript.isEmpty ? "Listening…" : voice.liveTranscript)
                        .font(Theme.mono(11))
                        .foregroundStyle(voice.liveTranscript.isEmpty ? Theme.textFaint : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.red).frame(width: 5, height: 5)
                        Text(timeLabel(voice.listeningElapsed))
                            .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                        Text("· release SPACE to send")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                    }
                }
            } else if !voice.liveTranscript.isEmpty {
                Text(voice.liveTranscript)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if voice.isSpeaking {
                Text("ESC or click to stop")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.red)
            } else {
                Text("Hold SPACE to talk")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(14)
        .panel()
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
