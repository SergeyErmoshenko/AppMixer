import Foundation
import Testing

/// The look-ahead limiter behind the boost. It is what keeps loudness
/// climbing once the slider passes ~120% instead of a per-sample saturator
/// flattening everything against the ceiling.
@Suite("boost: look-ahead limiter")
struct LimiterTests {
    /// Pushes a constant stereo frame `count` times, collecting the frame
    /// that came due after each push — the same advance/read order mix uses.
    private func pushed(_ limiter: TapMix.Limiter, level: Float, count: Int) -> [Float] {
        let frame = [Float](repeating: level, count: 2)
        var due: [Float] = []
        for _ in 0 ..< count {
            frame.withUnsafeBufferPointer { limiter.advance($0.baseAddress!, channels: 2) }
            due.append(limiter.delayed[0])
        }
        return due
    }

    /// Runs mix over a stereo program with a limiter attached, converged gain.
    private func mixed(_ program: [Float], targetGain: Float,
                       limiter: TapMix.Limiter) -> [Float] {
        var output = [Float](repeating: .nan, count: program.count)
        program.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                _ = TapMix.mix(
                    input: inPtr.baseAddress!,
                    inputLayout: TapMix.Layout(channels: 2, count: program.count),
                    output: outPtr.baseAddress!,
                    outputLayout: TapMix.Layout(channels: 2, count: program.count),
                    gain: TapMix.Gain(current: targetGain, target: targetGain, ramp: 1),
                    limiter: limiter
                )
            }
        }
        return output
    }

    private func rms(_ x: [Float]) -> Float {
        var sum: Float = 0
        for v in x { sum += v * v }
        return (sum / Float(max(x.count, 1))).squareRoot()
    }

    @Test("the ring delays by exactly one look-ahead window")
    func ringDelaysExactly() {
        let limiter = TapMix.Limiter(sampleRate: 48000, channels: 2)
        let warmup = limiter.capacity

        let due = pushed(limiter, level: 0.5, count: warmup + 4)

        #expect(due[0 ..< warmup].allSatisfy { $0 == 0 }) // window fills with silence
        #expect(due[warmup...].allSatisfy { $0 == 0.5 }) // then the signal, whole
    }

    @Test("the follower attacks fast and releases slow")
    func envelopeDynamics() {
        let limiter = TapMix.Limiter(sampleRate: 48000, channels: 2)

        _ = pushed(limiter, level: 1, count: 2400) // 50 ms at full scale
        #expect(limiter.envelope > 0.99) // attack τ = 0.3 ms: fully up

        _ = pushed(limiter, level: 0, count: 7200) // 150 ms of silence
        #expect(limiter.envelope > 0.3 && limiter.envelope < 0.4) // release τ = 150 ms: ≈ 1/e
    }

    @Test("reduction engages only above unity and only when the envelope demands it")
    func reductionBounds() {
        let limiter = TapMix.Limiter(sampleRate: 48000, channels: 2)
        #expect(limiter.reduction(forGain: 3) == 1) // silent program: nothing to hold back

        _ = pushed(limiter, level: 1, count: 2400) // envelope ≈ 1
        #expect(abs(limiter.reduction(forGain: 3) - TapMix.Limiter.ceiling / 3) < 1e-5)
        #expect(limiter.reduction(forGain: 0.5) == 1) // sub-unity gain never reduces
    }

    @Test("a hot burst is held at the ceiling, quiet detail still gets the full boost")
    func burstLimitedQuietBoosted() {
        // 1000 frames at 0.9, then 12000 frames at 0.05 — one loud passage,
        // then a quiet one long enough for the reduction to fully release
        // (the follower decays toward the quiet level, τ = 150 ms). Gain 3.
        let limiter = TapMix.Limiter(sampleRate: 48000, channels: 2)
        var program = [Float](repeating: 0.9, count: 1000 * 2)
        program.append(contentsOf: [Float](repeating: 0.05, count: 12000 * 2))

        let output = mixed(program, targetGain: 3, limiter: limiter)

        // The burst rides just under full scale — held, not flattened into a
        // square and not clipped (the old tanh shipped its top at ≈ ±1.0).
        let burst = output[1000 * 2 ..< 1240 * 2]
        #expect(burst.allSatisfy { $0 > 0.9 && $0 <= 1.0 })
        // Deep into the quiet passage the reduction has fully released:
        // the full 3× lands sample-exact.
        #expect(output[program.count - 1] == Float(0.05) * 3)
    }

    @Test("loudness keeps climbing across the boost travel")
    func loudnessClimbsWithGain() {
        // Crest-rich program: 10% loud, 90% quiet — the shape where the old
        // saturator's loudness stalled once the crests hit the ceiling.
        let limiterLow = TapMix.Limiter(sampleRate: 48000, channels: 2)
        let limiterHigh = TapMix.Limiter(sampleRate: 48000, channels: 2)
        var program: [Float] = []
        for _ in 0 ..< 6 {
            program.append(contentsOf: [Float](repeating: 0.9, count: 4800 * 2))
            program.append(contentsOf: [Float](repeating: 0.3, count: 43200 * 2))
        }

        let gentle = mixed(program, targetGain: 1.5, limiter: limiterLow)
        let full = mixed(program, targetGain: 3, limiter: limiterHigh)

        #expect(rms(full) > rms(gentle) * 1.3) // ≈ +2.3 dB minimum, measured ≈ +4.7
        #expect(full.allSatisfy { abs($0) <= 1.0 }) // and still no clipping
    }

    @Test("attenuation stays bit-exact even with the limiter attached")
    func attenuationBitExact() {
        let limiter = TapMix.Limiter(sampleRate: 48000, channels: 2)
        let program = [Float](repeating: 0.5, count: 1000 * 2)

        let output = mixed(program, targetGain: 0.5, limiter: limiter)

        #expect(output[0 ..< limiter.capacity * 2].allSatisfy { $0 == 0 }) // window warmup (frames × channels)
        #expect(output[(limiter.capacity * 2)...].allSatisfy { $0 == 0.25 }) // exactly 0.5 × 0.5
    }

    @Test("reset clears the window and the follower")
    func resetClears() {
        let limiter = TapMix.Limiter(sampleRate: 48000, channels: 2)
        _ = pushed(limiter, level: 1, count: 2400)
        #expect(limiter.envelope > 0.9)

        limiter.reset()

        #expect(limiter.envelope == 0)
        let due = pushed(limiter, level: 0.1, count: 1)
        #expect(due[0] == 0) // no pre-reset audio replays out of the window
    }
}
