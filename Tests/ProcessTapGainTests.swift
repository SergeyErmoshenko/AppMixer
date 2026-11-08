import Testing

@Suite("VolumeTaper.gain")
struct VolumeTaperTests {
    @Test("endpoints map to silence, unity, and full boost")
    func endpoints() {
        #expect(VolumeTaper.gain(position: 0) == 0)
        #expect(VolumeTaper.gain(position: 1) == 1)
        #expect(VolumeTaper.gain(position: VolumeTaper.maxPosition) == VolumeTaper.maxPosition)
    }

    @Test("clamps out-of-range positions")
    func clamps() {
        #expect(VolumeTaper.gain(position: -0.5) == 0)
        #expect(VolumeTaper.gain(position: 3) == VolumeTaper.maxPosition)
    }

    @Test("midpoint sits well below linear −6 dB so the bottom of the travel breathes")
    func midpointTapered() {
        // Cube law: 0.5 → 0.125 (≈ −18 dB), not the 0.5 a linear map would give.
        #expect(VolumeTaper.gain(position: 0.5) == 0.125)
    }

    @Test("boost region is linear: gain equals position above unity")
    func boostIsLinear() {
        #expect(VolumeTaper.gain(position: 1.5) == 1.5)
        #expect(VolumeTaper.gain(position: 1.2) == 1.2)
        #expect(VolumeTaper.gain(position: 1.0001) == 1.0001)
    }

    @Test("monotonically increasing across the travel, attenuation and boost")
    func monotonic() {
        var previous = VolumeTaper.gain(position: 0)
        for step in 1 ... 40 {
            let gain = VolumeTaper.gain(position: Float(step) / 20)
            #expect(gain > previous)
            previous = gain
        }
    }
}
