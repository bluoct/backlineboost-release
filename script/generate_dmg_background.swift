#!/usr/bin/env swift
// Generates the DMG window background (script/dmg-template/background.tiff).
//
// Draws the drag-to-install cue: the Backline Boost wordmark and an arrow
// from the app icon position to the Applications position. Icon
// positions in the art must stay in sync with the Finder icon coordinates
// recorded in script/dmg-template/DS_Store (app at 160,190 / Applications at
// 480,190 / README.txt at 320,335 — window content 640x400, icon size 112).
//
// usage: swift script/generate_dmg_background.swift <output-dir>
//   emits background.png (640x400) and background@2x.png (1280x800);
//   combine with: tiffutil -cathidpicheck background.png background@2x.png \
//     -out script/dmg-template/background.tiff

import AppKit
import Foundation

let canvas = CGSize(width: 640, height: 400)
let brandOrange = NSColor(calibratedRed: 0.96, green: 0.64, blue: 0.14, alpha: 1)

// Top-based y coordinates (matching Finder icon positions) -> CG bottom-left.
func cgY(_ topY: CGFloat) -> CGFloat { canvas.height - topY }

func drawBackground(in ctx: CGContext) {
    // Moderate-grey vertical gradient, slightly lighter at the top — mid grey
    // keeps Finder's icon labels legible in BOTH appearance modes (labels
    // render black in light mode and white in dark mode).
    let colors = [
        NSColor(calibratedRed: 0.64, green: 0.64, blue: 0.66, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.56, green: 0.56, blue: 0.58, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvas.height),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Wordmark, centered near the top.
    let wordmark = NSAttributedString(
        string: "Backline Boost",
        attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 0.92),
        ]
    )
    let wordmarkSize = wordmark.size()
    wordmark.draw(at: CGPoint(x: (canvas.width - wordmarkSize.width) / 2, y: cgY(52) - wordmarkSize.height / 2))

    // Arrow between the icon positions (icons are 112pt, centers at x 160/480).
    let arrowY = cgY(190)
    let shaftStart: CGFloat = 236
    let headTip: CGFloat = 404
    let headLength: CGFloat = 30
    let headHalfWidth: CGFloat = 17

    ctx.setStrokeColor(brandOrange.cgColor)
    ctx.setLineWidth(11)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: shaftStart, y: arrowY))
    ctx.addLine(to: CGPoint(x: headTip - headLength + 2, y: arrowY))
    ctx.strokePath()

    ctx.setFillColor(brandOrange.cgColor)
    ctx.move(to: CGPoint(x: headTip, y: arrowY))
    ctx.addLine(to: CGPoint(x: headTip - headLength, y: arrowY + headHalfWidth))
    ctx.addLine(to: CGPoint(x: headTip - headLength, y: arrowY - headHalfWidth))
    ctx.closePath()
    ctx.fillPath()
    // The band below the arrow stays clear: README.txt sits at (320, 310).
}

func render(scale: CGFloat, to url: URL) {
    let pixelWidth = Int(canvas.width * scale)
    let pixelHeight = Int(canvas.height * scale)
    let ctx = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: scale, y: scale)

    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    drawBackground(in: ctx)
    NSGraphicsContext.current = previous

    let image = ctx.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    // 72/144 dpi metadata so tiffutil's hidpi check pairs the two renders.
    let properties: [CFString: Any] = [
        kCGImagePropertyDPIWidth: 72 * scale,
        kCGImagePropertyDPIHeight: 72 * scale,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("failed to write \(url.path)")
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate_dmg_background.swift <output-dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
render(scale: 1, to: outDir.appendingPathComponent("background.png"))
render(scale: 2, to: outDir.appendingPathComponent("background@2x.png"))
print("wrote \(outDir.path)/background.png and background@2x.png")
