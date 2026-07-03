#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: make-dmg-background.swift <output.png>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 660, height: 420)
let image = NSImage(size: size)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xff) / 255
    let g = CGFloat((hex >> 8) & 0xff) / 255
    let b = CGFloat(hex & 0xff) / 255
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha)
}

func drawString(_ text: String, at point: NSPoint, size fontSize: CGFloat, weight: NSFont.Weight, color textColor: NSColor, alignment: NSTextAlignment = .center) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
    ]
    text.draw(in: NSRect(x: point.x, y: point.y, width: 660 - point.x * 2, height: fontSize + 12), withAttributes: attrs)
}

func drawCentered(_ text: String, centerX: CGFloat, y: CGFloat, size fontSize: CGFloat, weight: NSFont.Weight, color textColor: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
    ]
    text.draw(in: NSRect(x: centerX - 92, y: y, width: 184, height: fontSize + 12), withAttributes: attrs)
}

image.lockFocus()

let bounds = NSRect(origin: .zero, size: size)
color(0xf8f9ff).setFill()
bounds.fill()

let gradient = NSGradient(colors: [
    color(0xeaf1ff),
    color(0xffffff),
    color(0xeef7ff),
])!
gradient.draw(in: bounds, angle: 28)

color(0x0a84ff, 0.13).setFill()
NSBezierPath(ovalIn: NSRect(x: -72, y: 244, width: 220, height: 220)).fill()
color(0x7e6bae, 0.12).setFill()
NSBezierPath(ovalIn: NSRect(x: 492, y: -74, width: 210, height: 210)).fill()

let panel = NSBezierPath(roundedRect: NSRect(x: 58, y: 58, width: 544, height: 284), xRadius: 32, yRadius: 32)
color(0xffffff, 0.64).setFill()
panel.fill()
color(0xffffff, 0.72).setStroke()
panel.lineWidth = 1.2
panel.stroke()

drawString("micaGO", at: NSPoint(x: 0, y: 350), size: 34, weight: .semibold, color: color(0x182033))
drawString("Drag to install", at: NSPoint(x: 0, y: 319), size: 15, weight: .medium, color: color(0x5b6578))

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 286, y: 204))
arrow.line(to: NSPoint(x: 374, y: 204))
arrow.move(to: NSPoint(x: 358, y: 219))
arrow.line(to: NSPoint(x: 374, y: 204))
arrow.line(to: NSPoint(x: 358, y: 189))
color(0x0a84ff, 0.58).setStroke()
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

drawCentered("micaGO", centerX: 180, y: 96, size: 14, weight: .medium, color: color(0x2b3346))
drawCentered("Applications", centerX: 480, y: 96, size: 14, weight: .medium, color: color(0x2b3346))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("failed to render background\n", stderr)
    exit(1)
}

try png.write(to: outputURL)
