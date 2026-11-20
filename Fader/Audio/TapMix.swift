import Foundation

/// The pure math of ProcessTap's render: ramped gain plus channel-layout
/// adaptation, split from the tap so it is unit-testable without a HAL.
/// Called from the real-time IO callback — no allocation, no locks.
enum TapMix {
    /// One interleaved buffer's shape: channel count and total sample count.
    struct Layout {
        let channels: Int
        let count: Int
    }

    /// The gain ramp state: where it is, where it heads, how fast per frame.
    struct Gain {
        let current: Float
        let target: Float
        let ramp: Float
    }

    /// Look-ahead peak limiter for the boost region.
    ///
    /// The original boost tamed peaks with a per-sample tanh soft ceiling
    /// (knee 0.85). For mastered music whose crests already sit near full
    /// scale, gain above ~120% just pushed more of the waveform into the
    /// saturator: the top of the wave was already at the ceiling, so
    /// loudness — what the ear tracks — stopped climbing, and 150–300% all
    /// sounded alike. A limiter instead rides the program envelope: a
    /// one-pole follower (0.3 ms attack, 150 ms release, linked across
    /// channels so the stereo image does not sway) watches the *undelayed*
    /// input, and the gain reduction it demands is applied to the same
    /// samples one look-ahead window later — fully in place before the peak
    /// that caused it arrives. The waveform keeps its shape and average
    /// level keeps climbing across the whole boost travel. A thin tanh
    /// safety clip (softCeiling) only cleans up the sub-millisecond
    /// overshoot a transient sneaking through the attack lag leaves.
    ///
    /// The ring costs two allocations at tap activation and then runs
    /// lock-free and allocation-free on the RT thread. While the frame gain
    /// is at or below unity the reduction is 1: attenuation stays bit-exact
    /// (samples emerge one window late but otherwise untouched).
    final class Limiter {
        /// Limited peaks land here; a hair below 1 leaves headroom for the
        /// safety clip and inter-sample peaks.
        static let ceiling: Float = 0.98
        /// One-pole time constants, seconds. Fast enough to be ready for the
        /// next bass half-cycle, slow enough that the reduction does not
        /// ripple with the waveform itself (envelope ripple at signal
        /// frequency would be AM distortion).
        static let attackTime: Float = 0.0003
        static let releaseTime: Float = 0.150
        /// How far ahead the follower watches, seconds. Must exceed the
        /// attack time with margin — the whole point is that the reduction
        /// settles before the peak that caused it reaches the output.
        static let lookaheadTime: Float = 0.005

        /// Frames of look-ahead; sample-rate dependent, fixed at activation.
        let capacity: Int
        let channels: Int
        /// The frame that just came due; advance() writes it, the mix reads
        /// it. One scratch frame, reused every call.
        let delayed: UnsafeMutablePointer<Float>
        private let ring: UnsafeMutablePointer<Float>
        private var writeIndex = 0
        private(set) var envelope: Float = 0
        private let attack: Float
        private let release: Float

        /// - Parameters:
        ///   - sampleRate: the aggregate stream's rate; sizes the window and
        ///     the envelope coefficients.
        ///   - channels: the tap's interleaved channel count (stereo mixdown
        ///     in practice). A render whose buffer pair mismatches bypasses
        ///     the limiter rather than corrupting the ring.
        init(sampleRate: Float, channels: Int) {
            self.channels = channels
            capacity = max(1, Int((sampleRate * Self.lookaheadTime).rounded(.up)))
            attack = 1 - exp(-1 / (sampleRate * Self.attackTime))
            release = 1 - exp(-1 / (sampleRate * Self.releaseTime))
            ring = .allocate(capacity: capacity * channels)
            delayed = .allocate(capacity: channels)
            ring.initialize(repeating: 0, count: capacity * channels)
            delayed.initialize(repeating: 0, count: channels)
        }

        deinit {
            ring.deallocate()
            delayed.deallocate()
        }

        /// Clears the follower and the ring. Used while the tap is muted, so
        /// unmuting never replays pre-mute audio out of the window.
        func reset() {
            writeIndex = 0
            envelope = 0
            ring.initialize(repeating: 0, count: capacity * channels)
        }

        /// Feeds one undelayed frame (the future) into the ring and the
        /// follower, and writes the frame that just came due into `delayed`.
        /// The caller then reads `delayed` and `reduction(forGain:)` — in
        /// that order, so the newest future frame already counts toward the
        /// reduction of the oldest played one.
        func advance(_ newFrame: UnsafePointer<Float>, channels count: Int) {
            var level: Float = 0
            for c in 0 ..< count {
                level = max(level, abs(newFrame[c]))
            }
            let coefficient = level > envelope ? attack : release
            envelope += (level - envelope) * coefficient

            let base = writeIndex * channels
            for c in 0 ..< count {
                delayed[c] = ring[base + c]
                ring[base + c] = newFrame[c]
            }
            writeIndex = (writeIndex + 1) % capacity
        }

        /// Gain reduction demanded right now so that `gain × envelope` lands
        /// on the ceiling. 1 = untouched. Sized against the target (not the
        /// mid-ramp) gain, so a ramp-up never overshoots at its end.
        func reduction(forGain gain: Float) -> Float {
            min(1, Self.ceiling / max(gain * envelope, .leastNonzeroMagnitude))
        }
    }

    /// Boost soft ceiling: above the knee the curve bends via tanh toward ±1 —
    /// slope-continuous at the knee and smoothly saturating, instead of the
    /// hard clip the DAC would otherwise apply. Now a thin *safety* net only:
    /// the look-ahead limiter does the loudness work, and this catches the
    /// sub-millisecond residue a transient sneaking through the attack lag
    /// leaves. Only invoked while the frame's gain exceeds unity, so
    /// attenuation and unity remain bit-exact.
    static func softCeiling(_ x: Float) -> Float {
        let knee: Float = 0.95
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let overshoot = (magnitude - knee) / (1 - knee)
        return copysign(knee + (1 - knee) * tanh(overshoot), x)
    }

    /// Applies the ramped gain while adapting the tap's channel layout to the
    /// output stream's. The tap always delivers a stereo mixdown, but the
    /// output can be mono (a Bluetooth headset dropping to HFP mid-call) or
    /// wider; index-matched copying would smear interleaved frames across
    /// time. Equal layouts copy 1:1, a narrower output averages each frame's
    /// channels, a wider one repeats the last input channel. When `limiter`
    /// is non-nil and the pair's channel count matches its ring, boosted
    /// frames also pass through the look-ahead limiter; otherwise the soft
    /// ceiling alone guards the boost. Returns the gain after the final frame.
    static func mix(input: UnsafePointer<Float>, inputLayout: Layout,
                    output: UnsafeMutablePointer<Float>, outputLayout: Layout,
                    gain: Gain, limiter: Limiter? = nil) -> Float {
        let inChannels = max(1, inputLayout.channels)
        let outChannels = max(1, outputLayout.channels)
        let frames = min(inputLayout.count / inChannels, outputLayout.count / outChannels)
        let targetGain = gain.target
        let ramp = gain.ramp
        var frameGain = gain.current
        let limited = limiter.flatMap { $0.channels == inChannels ? $0 : nil }

        for frame in 0 ..< frames {
            frameGain += (targetGain - frameGain) * ramp
            let boosting = frameGain > 1.0001
            // Feed the future: the follower and the ring see the undelayed
            // stream; the mix below plays what came due one window ago, so
            // the reduction is already in place when its peak arrives.
            if let limited {
                limited.advance(input + frame * inChannels, channels: inChannels)
            }
            let reduction: Float
            if boosting, let limited {
                reduction = limited.reduction(forGain: targetGain)
            } else {
                reduction = 1
            }
            let inBase = frame * inChannels
            let outBase = frame * outChannels
            let source: UnsafePointer<Float>
            if let limited {
                source = UnsafePointer(limited.delayed)
            } else {
                source = input + inBase
            }
            if inChannels == outChannels {
                for channel in 0 ..< outChannels {
                    let sample = source[channel] * frameGain * reduction
                    output[outBase + channel] = boosting ? softCeiling(sample) : sample
                }
            } else if outChannels == 1 {
                var sum: Float = 0
                for channel in 0 ..< inChannels {
                    sum += source[channel]
                }
                let sample = sum / Float(inChannels) * frameGain * reduction
                output[outBase] = boosting ? softCeiling(sample) : sample
            } else {
                for channel in 0 ..< outChannels {
                    let sample = source[min(channel, inChannels - 1)] * frameGain * reduction
                    output[outBase + channel] = boosting ? softCeiling(sample) : sample
                }
            }
        }
        // Snap once converged: stops the asymptotic tail (denormal-prone
        // when ramping to 0 on non-Apple-silicon FPUs).
        if abs(frameGain - targetGain) < 1e-6 {
            frameGain = targetGain
        }
        let written = frames * outChannels
        if written < outputLayout.count {
            output.advanced(by: written).update(repeating: 0, count: outputLayout.count - written)
        }
        return frameGain
    }
}
