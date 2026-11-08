// Renders the site favicon: the app icon's three faders on a full-bleed
// dark circle. Tracks and knobs are thicker than the app icon's so the
// shape survives 16-32 px tab sizes. Regenerate with `make favicon`.
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

image.lockFocus()

// Background: circle with the site's dark gradient, no margin.
let circle = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: canvas, height: canvas))
let gradient = NSGradient(
    starting: NSColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1),
    ending: NSColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1)
)!
gradient.draw(in: circle, angle: -90)

// Three fader tracks with knobs at different positions.
let trackWidth: CGFloat = 56
let trackHeight: CGFloat = 540
let trackY = (canvas - trackHeight) / 2
let knobRadius: CGFloat = 104
let positions: [(x: CGFloat, knob: CGFloat)] = [
    (canvas / 2 - 200, 0.30),
    (canvas / 2, 0.72),
    (canvas / 2 + 200, 0.48),
]

for fader in positions {
    let track = NSBezierPath(
        roundedRect: NSRect(x: fader.x - trackWidth / 2, y: trackY, width: trackWidth, height: trackHeight),
        xRadius: trackWidth / 2,
        yRadius: trackWidth / 2
    )
    NSColor(white: 1, alpha: 0.18).setFill()
    track.fill()

    let knobCenterY = trackY + trackHeight * fader.knob
    // Filled part of the track below the knob.
    let fill = NSBezierPath(
        roundedRect: NSRect(
            x: fader.x - trackWidth / 2,
            y: trackY,
            width: trackWidth,
            height: knobCenterY - trackY
        ),
        xRadius: trackWidth / 2,
        yRadius: trackWidth / 2
    )
    NSColor(red: 0.36, green: 0.61, blue: 1.0, alpha: 1).setFill()
    fill.fill()

    let knobRect = NSRect(
        x: fader.x - knobRadius,
        y: knobCenterY - knobRadius,
        width: knobRadius * 2,
        height: knobRadius * 2
    )
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: knobRect).fill()
    NSShadow().set()
}

image.unlockFocus()

// Write the master PNG; the Makefile downsizes it with sips.
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render favicon")
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "favicon-1024.png")
do {
    try png.write(to: output)
} catch {
    fatalError("Failed to write \(output.path): \(error)")
}

print("Wrote \(output.path)")
