import SwiftUI

/// One mixer row: app icon, name, volume percentage, and a ControlSlider.
struct AppRowView: View {
    /// Vertical rhythm of a row — name line plus its slider; MixerView's
    /// scroll-frame height relies on it.
    static let rowHeight: CGFloat = 53

    @Environment(MixerEngine.self) private var engine
    let app: AudioApp

    var body: some View {
        let entry = engine.volume(for: app)
        // A paused (silent) row dims so it reads apart from live ones.
        let pausedDim: Double = app.isPlaying ? 1.0 : 0.5

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(entry.isMuted ? "muted" : "\(Int(entry.volume * 100))%")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .opacity(pausedDim)

            ControlSlider(
                value: Binding(
                    get: { entry.volume },
                    set: { engine.setVolume($0, for: app) }
                ),
                icon: sliderIcon(entry),
                iconDimmed: entry.isMuted,
                onIconTap: { engine.toggleMute(for: app) }
            )
            .opacity((entry.isMuted ? 0.55 : 1.0) * pausedDim)
        }
        .padding(.horizontal, 6)
        .animation(.easeOut(duration: 0.2), value: app.isPlaying)
        .contextMenu {
            Button("Reset to 100%") { engine.reset(app) }
        }
    }

    private func sliderIcon(_ entry: AppVolume) -> String {
        if entry.isMuted { return "speaker.slash.fill" }
        switch entry.volume {
        case 0: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
