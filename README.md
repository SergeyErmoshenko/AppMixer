# AppMixer

A personal macOS per-app volume mixer, Windows-style: one slider per app in a
menu bar popover, a master volume on top. Every running application is listed
right away — even before it makes sound — so its volume is always editable; a
preset level applies from the app's first sound.

Per-app volume goes up to 200% (+6 dB): the boost zone is tinted on the
slider, and boosted peaks pass a soft-knee limiter instead of hard-clipping.
The slider is magnetic at 50 / 100 / 150% marks; 100% is special — the app's
native, untouched audio path (no tap, bit-perfect).

Driverless and crash-safe: built on Core Audio process taps (macOS 14.4+).
Apps left at 100% are never touched (bit-perfect native playback). If AppMixer
quits or crashes, every tapped app instantly returns to its native audio path —
the failure mode is "no per-app control", never "no audio".

This is a fork of [fader by pantafive](https://github.com/pantafive/fader)
(MIT), stripped down to per-app volume + mute, all-apps rows, launch-at-login,
and a Windows-mixer panel. Huge thanks to the original author.

## Build

Requires macOS 15+, Xcode 26, and [xcodegen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen
open AppMixer.xcodeproj   # select your team, then Run
```

Or headless: `make run`. First slider move triggers the macOS system-audio
permission prompt. Unit tests: `make test`.

## License

MIT — see [LICENSE](LICENSE). Based on fader, © pantafive.
