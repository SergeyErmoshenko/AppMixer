import SwiftUI

/// Control-Center-style volume slider: a capsule track filled to the current
/// value, a circular thumb riding the fill edge (HIG: macOS linear sliders
/// have a visible thumb), and a tappable leading icon for mute.
///
/// The travel can exceed unity (`maxValue` > 1): the boost region gets a
/// tinted track and an orange fill, and `marks` makes the slider magnetic —
/// a drag or scroll that lands within `snapEpsilon` of a mark captures to it,
/// so hitting exactly 100% (unity: no tap, bit-perfect playback) is easy.
struct ControlSlider: View {
    @Binding var value: Float
    /// Top end of the travel in value units (1 = no boost region).
    var maxValue: Float = 1
    /// Magnetic positions in value units; empty disables snapping and ticks.
    var marks: [Float] = []
    var icon: String
    var iconDimmed: Bool = false
    var onIconTap: (() -> Void)?

    /// How close (in value units) a drag must land for a mark to capture it.
    private static let snapEpsilon: Float = 0.03
    private let height: CGFloat = 22

    @State private var isDragging = false
    @State private var scrollMonitor: Any?
    @Environment(\.colorScheme) private var colorScheme

    private var trackColor: Color {
        Color(nsColor: .quaternarySystemFill)
    }

    private var isBoosting: Bool { value > 1.0 }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = CGFloat(value / max(maxValue, .leastNonzeroMagnitude))
            // The thumb center stays inside the capsule; fill always reaches it.
            let thumbCenter = height / 2 + (width - height) * fraction
            let unityEdge = height / 2 + (width - height) * CGFloat(1 / max(maxValue, 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    }

                // The boost region reads as a distinct zone before the thumb
                // ever enters it.
                if maxValue > 1 {
                    GeometryReader { geo in
                        Color.orange.opacity(0.18)
                            .frame(width: max(geo.size.width - unityEdge, 0))
                            .clipShape(Capsule())
                    }
                }

                Capsule()
                    .fill(isBoosting ? Color.orange : .white)
                    .frame(width: thumbCenter + height / 2)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(isBoosting ? Color.orange : .white)
                            .frame(width: height, height: height)
                            .shadow(color: .black.opacity(0.25), radius: isDragging ? 4 : 2, y: 1)
                    }

                tickMarks(width: width)

                Button {
                    onIconTap?()
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(iconDimmed ? 0.25 : 0.6))
                        .frame(width: height, height: height)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .compositingGroup()
            .animation(.easeOut(duration: 0.08), value: isDragging)
            // Smooths scroll-wheel steps; direct finger drags stay 1:1.
            .animation(isDragging ? nil : .easeOut(duration: 0.12), value: value)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        // A motionless touch on the icon is a mute tap, not a drag.
                        if !isDragging, gesture.translation == .zero, gesture.location.x < height, onIconTap != nil {
                            return
                        }
                        isDragging = true
                        let usable = max(width - height, 1)
                        let raw = Float(min(max((gesture.location.x - height / 2) / usable, 0), 1)) * maxValue
                        value = Self.snapped(raw, marks: marks)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: height)
        // Scroll over the slider adjusts the value. The monitor lives only
        // while the cursor is over this slider, so it sees exactly the events
        // meant for it; installing on hover (not appear) keeps one popover
        // open/close cycle from stacking monitors.
        .onHover { hovering in
            if hovering, scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    adjust(by: event)
                    return nil // consumed: don't also scroll the app list
                }
            } else if !hovering {
                removeScrollMonitor()
            }
        }
        .onDisappear(perform: removeScrollMonitor)
    }

    /// Tick marks at each magnetic position; the unity mark (100%) is
    /// stronger and accent-tinted — it's the "native, untouched audio" spot.
    @ViewBuilder
    private func tickMarks(width: CGFloat) -> some View {
        if maxValue > 1 {
            // 0 sits under the mute icon and maxValue under the thumb-at-max;
            // draw only the interior ticks.
            ForEach(marks.filter { $0 > 0 && $0 < maxValue }, id: \.self) { mark in
                let x = height / 2 + (width - height) * CGFloat(mark / maxValue)
                let isUnity = mark == 1
                RoundedRectangle(cornerRadius: 1)
                    .fill(isUnity ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.35))
                    .frame(width: 2, height: isUnity ? 10 : 6)
                    .position(x: x, y: height / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private static func snapped(_ raw: Float, marks: [Float]) -> Float {
        guard let mark = marks.first(where: { abs($0 - raw) <= snapEpsilon }) else { return raw }
        return mark
    }

    /// Trackpads send many precise pixel deltas per gesture, wheel mice send
    /// coarse line deltas — scale each so a comfortable gesture sweeps
    /// roughly half the slider.
    private func adjust(by event: NSEvent) {
        let scale: Float = event.hasPreciseScrollingDeltas ? 1 / 120 : 1 / 12
        let raw = min(max(value + Float(event.scrollingDeltaY) * scale, 0), maxValue)
        value = Self.snapped(raw, marks: marks)
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}
