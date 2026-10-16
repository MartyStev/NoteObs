// Draws the NoteObs app icon: the seven stars of the Big Dipper, one per note, each glowing in the
// colour of its note, on a night sky. Every size is rendered from the vector drawing rather than
// scaled down, so the small sizes stay crisp.
//
//   swift Tools/make-icon.swift <output.iconset>
//   iconutil -c icns <output.iconset> -o Assets/AppIcon.icns
//
// `make icon` runs both.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The drawing works in a 1024-point canvas; each rendered size scales it.
let canvas: CGFloat = 1024

/// macOS icon grid: the rounded square sits 100 pt inside the canvas, leaving room for its shadow.
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

/// The seven stars, handle to bowl, in canvas coordinates (y grows upwards). Their order matches the
/// notes: the end of the handle is note 1, the bowl's far corner is note 7.
struct Star {
    let position: CGPoint
    let radius: CGFloat
    let color: NSColor
}

let stars: [Star] = [
    Star(position: CGPoint(x: 232, y: 668), radius: 15, color: .systemRed),       // Alkaid
    Star(position: CGPoint(x: 352, y: 610), radius: 17, color: .systemOrange),    // Mizar
    Star(position: CGPoint(x: 458, y: 566), radius: 19, color: .systemYellow),    // Alioth
    Star(position: CGPoint(x: 560, y: 508), radius: 13, color: .systemGreen),     // Megrez
    Star(position: CGPoint(x: 586, y: 352), radius: 16, color: .systemTeal),      // Phecda
    Star(position: CGPoint(x: 790, y: 336), radius: 17, color: .systemBlue),      // Merak
    Star(position: CGPoint(x: 806, y: 534), radius: 19, color: .systemPurple)     // Dubhe
]

/// The figure's lines: along the handle, round the bowl, and the bowl closed back to Megrez.
let lines: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 3)]

/// Deterministic faint background stars, so every run draws the same sky.
func backgroundStars(count: Int) -> [(CGPoint, CGFloat, CGFloat)] {
    var seed: UInt64 = 0x5EED_0B5
    func next() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) % 10_000) / 10_000
    }
    return (0..<count).map { _ in
        let point = CGPoint(x: bodyRect.minX + next() * bodyRect.width, y: bodyRect.minY + next() * bodyRect.height)
        return (point, 1.5 + next() * 3, 0.15 + next() * 0.35)
    }
}

func draw(in context: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / canvas
    context.scaleBy(x: scale, y: scale)
    let detailed = pixels >= 64

    let body = CGPath(roundedRect: bodyRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(body)
    context.setFillColor(NSColor(srgbRed: 0.05, green: 0.07, blue: 0.18, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()

    // Night sky: deep indigo at the top fading to near-black navy.
    let sky = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            NSColor(srgbRed: 0.17, green: 0.12, blue: 0.38, alpha: 1).cgColor,
            NSColor(srgbRed: 0.05, green: 0.07, blue: 0.18, alpha: 1).cgColor,
            NSColor(srgbRed: 0.02, green: 0.03, blue: 0.09, alpha: 1).cgColor
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        sky,
        start: CGPoint(x: 300, y: bodyRect.maxY),
        end: CGPoint(x: 700, y: bodyRect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // A soft glow behind the bowl, so the figure sits in light rather than on flat colour.
    let haze = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            NSColor(srgbRed: 0.45, green: 0.40, blue: 0.95, alpha: 0.28).cgColor,
            NSColor(srgbRed: 0.45, green: 0.40, blue: 0.95, alpha: 0).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(haze, startCenter: CGPoint(x: 600, y: 480), startRadius: 0, endCenter: CGPoint(x: 600, y: 480), endRadius: 420, options: [])

    if detailed {
        for (point, radius, alpha) in backgroundStars(count: 70) {
            context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in: CGRect(x: point.x - radius / 2, y: point.y - radius / 2, width: radius, height: radius))
        }
    }

    // The figure's lines: thin, pale, drawn under the stars.
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(detailed ? 6 : 14)
    context.setStrokeColor(NSColor(srgbRed: 0.80, green: 0.84, blue: 1, alpha: detailed ? 0.42 : 0.6).cgColor)
    for (from, to) in lines {
        context.move(to: stars[from].position)
        context.addLine(to: stars[to].position)
    }
    context.strokePath()

    // Each star: a coloured halo, then a white core with a faint coloured rim.
    for star in stars {
        let haloRadius = star.radius * (detailed ? 5.5 : 3.5)
        let halo = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                star.color.withAlphaComponent(0.85).cgColor,
                star.color.withAlphaComponent(0.25).cgColor,
                star.color.withAlphaComponent(0).cgColor
            ] as CFArray,
            locations: [0, 0.35, 1]
        )!
        context.drawRadialGradient(halo, startCenter: star.position, startRadius: 0, endCenter: star.position, endRadius: haloRadius, options: [])

        let core = star.radius * (detailed ? 1 : 1.6)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: star.position.x - core, y: star.position.y - core, width: core * 2, height: core * 2))
        if detailed {
            // Four short rays on the brightest stars give them a twinkle.
            if star.radius >= 17 {
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor)
                context.setLineWidth(3)
                let ray = star.radius * 2.6
                context.move(to: CGPoint(x: star.position.x - ray, y: star.position.y))
                context.addLine(to: CGPoint(x: star.position.x + ray, y: star.position.y))
                context.move(to: CGPoint(x: star.position.x, y: star.position.y - ray))
                context.addLine(to: CGPoint(x: star.position.x, y: star.position.y + ray))
                context.strokePath()
            }
        }
    }

    // No outline: a light edge reads as a frame on dark backgrounds at Finder and Dock sizes.
    context.restoreGState()
}

func render(pixels: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw NSError(domain: "make-icon", code: 1) }
    context.interpolationQuality = .high
    draw(in: context, pixels: pixels)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "make-icon", code: 3) }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// The sizes iconutil expects in an .iconset.
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points, to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2, to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("wrote \(output.path)")
