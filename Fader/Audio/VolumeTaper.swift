/// Slider-position → amplitude-gain mapping for the per-app process tap.
///
/// A linear position→amplitude map crams every audible step into the bottom
/// of the travel — 0.5 is only −6 dB, still loud, then the last sliver does
/// everything (the "loud, then nothing" complaint). The system volume slider
/// tapers, so the per-app tap must too or the two controls feel nothing alike.
/// Cube law is the standard audio-fader taper: equal slider travel ≈ equal
/// perceived-loudness change. Kept pure and free of HAL imports so it unit-tests
/// in the hostless bundle.
///
/// Above unity the slider keeps going to `maxPosition` (200%): the boost
/// region is linear — gain equals position, so 150% of travel is exactly
/// +3.5 dB and 200% is +6 dB. Boosted peaks are tamed by TapMix's soft
/// ceiling; attenuation stays bit-exact.
enum VolumeTaper {
    /// The slider's top end: 200% of native volume (+6 dB).
    static let maxPosition: Float = 2

    static func gain(position: Float) -> Float {
        let p = max(0, min(maxPosition, position))
        if p > 1 { return p } // linear boost: gain == position above unity
        return p * p * p
    }
}
