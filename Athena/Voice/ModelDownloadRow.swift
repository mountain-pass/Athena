import SwiftUI

/// The lifecycle every on-device model shares, regardless of who does the
/// downloading. Kokoro and CosyVoice are fetched by us (so we get byte
/// callbacks); Parakeet is fetched inside FluidAudio (so we infer progress
/// from bytes landing on disk). Both end up here, so the UI is identical.
enum ModelPhase: Equatable {
    case absent(String)                 // not downloaded — call to action
    case downloading(Double?)           // fraction, or nil when unmeasurable
    case loading(String)                // on disk, being loaded into memory
    case ready(String)
    case failed(String)
}

/// One rendering of model state, used by every model in the app so downloads
/// look and behave the same everywhere.
struct ModelDownloadRow: View {
    let phase: ModelPhase
    /// Shown under the bar during a download, e.g. "412 MB of 600 MB".
    var detail: String? = nil
    var downloadTitle = "Download model"
    var onStart: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .absent(let note):
                VStack(alignment: .leading, spacing: 6) {
                    Label(note, systemImage: "exclamationmark.circle.fill")
                        .font(Theme.mono(11)).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    if let onStart {
                        Button(downloadTitle) { onStart() }
                    }
                }

            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 5) {
                    // A determinate bar whenever we can measure, so the user
                    // can tell "slow" from "stuck".
                    if let fraction {
                        ProgressView(value: min(max(fraction, 0), 1))
                            .frame(maxWidth: 340)
                            .tint(Theme.amber)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 340)
                            .tint(Theme.amber)
                    }
                    HStack(spacing: 8) {
                        Text("Downloading…")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                        if let detail {
                            Text(detail)
                                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                        }
                    }
                }

            case .loading(let label):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label)
                        .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                }

            case .ready(let label):
                Label(label, systemImage: "checkmark.circle.fill")
                    .font(Theme.mono(11)).foregroundStyle(Theme.green)

            case .failed(let why):
                VStack(alignment: .leading, spacing: 6) {
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.mono(11)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if let onRetry {
                        Button {
                            onRetry()
                        } label: {
                            Label("RETRY", systemImage: "arrow.clockwise")
                                .font(Theme.label).kerning(1)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.amber).clipShape(Capsule())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
    }
}
