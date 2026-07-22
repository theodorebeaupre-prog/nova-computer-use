#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: render-dmg-background.swift <source.png> <output.png>\n", stderr)
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("Could not load source background.\n", stderr)
    exit(1)
}

let width = 660
let height = 420
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let sourceRatio = source.size.width / source.size.height
let targetRatio = CGFloat(width) / CGFloat(height)
var sourceRect = NSRect(origin: .zero, size: source.size)
if sourceRatio > targetRatio {
    let cropWidth = source.size.height * targetRatio
    sourceRect.origin.x = (source.size.width - cropWidth) / 2
    sourceRect.size.width = cropWidth
} else {
    let cropHeight = source.size.width / targetRatio
    sourceRect.origin.y = (source.size.height - cropHeight) / 2
    sourceRect.size.height = cropHeight
}
source.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: sourceRect, operation: .sourceOver, fraction: 1)

for rect in [NSRect(x: 112, y: 61, width: 116, height: 29), NSRect(x: 432, y: 61, width: 116, height: 29)] {
    NSColor.white.withAlphaComponent(0.42).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
}

NSGradient(starting: NSColor.black.withAlphaComponent(0.52), ending: .clear)?.draw(
    in: NSRect(x: 0, y: 310, width: width, height: 110), angle: -90
)

let titleStyle = NSMutableParagraphStyle()
titleStyle.alignment = .center
let title = NSAttributedString(string: "NOVA COMPUTER USE", attributes: [
    .font: NSFont.systemFont(ofSize: 25, weight: .bold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.96),
    .kern: 4.2,
    .paragraphStyle: titleStyle
])
title.draw(in: NSRect(x: 30, y: 365, width: 600, height: 34))

let subtitle = NSAttributedString(string: "DRAG TO INSTALL", attributes: [
    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.63),
    .kern: 2.4,
    .paragraphStyle: titleStyle
])
subtitle.draw(in: NSRect(x: 230, y: 118, width: 200, height: 20))

let orbit = NSBezierPath()
orbit.move(to: NSPoint(x: 225, y: 220))
orbit.curve(to: NSPoint(x: 435, y: 220), controlPoint1: NSPoint(x: 280, y: 175), controlPoint2: NSPoint(x: 380, y: 175))
orbit.lineWidth = 2
NSColor.white.withAlphaComponent(0.62).setStroke()
orbit.stroke()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 435, y: 220))
arrow.line(to: NSPoint(x: 421, y: 226))
arrow.move(to: NSPoint(x: 435, y: 220))
arrow.line(to: NSPoint(x: 427, y: 207))
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: outputURL, options: .atomic)
