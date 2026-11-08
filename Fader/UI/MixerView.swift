import SwiftUI

/// The menu bar popover, Windows-mixer style: the master (system) volume on
/// top, then one row per app. An app appears the first time it makes sound
/// and keeps its row until it quits — like the Windows volume mixer.
struct MixerView: View {
    @Environment(MixerEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if engine.needsAudioCapturePermission {
                PermissionBanner()
            }

            masterVolumeSection

            Divider()

            appsSection
        }
        .padding(12)
        .frame(width: 320)
    }

    /// The system-wide volume of the current default output device, exactly
    /// what the volume keys and Control Center control.
    private var masterVolumeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 14)
                Text("Output")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(engine.systemVolume.deviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            masterSlider
        }
        .padding(8)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A dead slider dims instead of snapping back when the device exposes no
    /// settable volume — and says why, so the greyed-out control reads as
    /// "this device runs its own volume" rather than a broken slider.
    private var masterSlider: some View {
        VStack(spacing: 4) {
            ControlSlider(
                value: Binding(
                    get: { engine.systemVolume.volume },
                    set: { engine.systemVolume.setVolume($0) }
                ),
                icon: engine.systemVolume.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                iconDimmed: engine.systemVolume.isMuted,
                onIconTap: engine.systemVolume.canMute ? { engine.systemVolume.toggleMute() } : nil
            )
            .disabled(!engine.systemVolume.canSetVolume)
            .opacity(engine.systemVolume.canSetVolume ? 1.0 : 0.4)
            if !engine.systemVolume.canSetVolume {
                Text("Volume is controlled on the device")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Apps audible right now, plus apps heard earlier this session or with a
    /// saved adjustment — hiding those would strand their saved volume.
    private var mixerApps: [AudioApp] {
        engine.processMonitor.apps.filter {
            $0.isPlaying || !engine.volume(for: $0).isNeutral || engine.hasPlayedThisSession($0)
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        if !engine.isStarted {
            waitingState
        } else if mixerApps.isEmpty {
            emptyState
        } else {
            // MenuBarExtra windows size to the content's ideal height, and a
            // ScrollView's ideal height is zero — give it an explicit one.
            let apps = mixerApps
            // Cap the viewport at six rows.
            let listHeight = CGFloat(min(apps.count, 6)) * AppRowView.rowHeight
            let rows = VStack(spacing: 8) {
                ForEach(apps) { app in
                    AppRowView(app: app)
                }
            }
            .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Apps")
                ScrollView { rows }.frame(height: listHeight)
            }
        }
    }

    /// Uppercase caps that label a free-floating list section (Apps).
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
    }

    private var waitingState: some View {
        HStack(spacing: 8) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Waiting for the audio system…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("Nothing is playing yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Play something and it will show up here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 16)
            Spacer()
        }
    }
}
