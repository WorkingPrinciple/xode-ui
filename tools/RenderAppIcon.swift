// SPDX-License-Identifier: GPL-3.0-only
// Original orbital doorway mark, not a game cover or third-party logo.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift tools/RenderAppIcon.swift <explicit-iconset-directory>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let colorSpace = CGColorSpaceCreateDeviceRGB()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Cannot allocate original icon bitmap.")
        }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let bounds = CGRect(x: 94, y: 94, width: 836, height: 836)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 184, cornerHeight: 184, transform: nil))
        context.clip()
        let sky = [CGColor(red: 0.06, green: 0.10, blue: 0.22, alpha: 1),
                   CGColor(red: 0.16, green: 0.32, blue: 0.48, alpha: 1),
                   CGColor(red: 0.76, green: 0.48, blue: 0.35, alpha: 1)]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: sky as CFArray,
                                        locations: [0, 0.58, 1]) else { fatalError("Cannot allocate icon gradient.") }
        context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 930),
                                   end: CGPoint(x: 512, y: 94), options: [])
        context.setFillColor(CGColor(red: 0.88, green: 0.89, blue: 0.82, alpha: 1))
        context.fillEllipse(in: CGRect(x: 638, y: 652, width: 142, height: 142))
        context.setFillColor(CGColor(red: 0.23, green: 0.39, blue: 0.49, alpha: 1))
        context.fillEllipse(in: CGRect(x: 670, y: 664, width: 142, height: 142))
        context.setFillColor(CGColor(red: 0.86, green: 0.92, blue: 0.95, alpha: 0.72))
        for point in [CGPoint(x: 254, y: 746), CGPoint(x: 410, y: 840), CGPoint(x: 542, y: 692)] {
            context.fillEllipse(in: CGRect(x: point.x, y: point.y, width: 7, height: 7))
        }
        let ridge = CGMutablePath()
        ridge.move(to: CGPoint(x: 94, y: 94))
        ridge.addLine(to: CGPoint(x: 94, y: 288))
        ridge.addLine(to: CGPoint(x: 316, y: 342))
        ridge.addLine(to: CGPoint(x: 484, y: 304))
        ridge.addLine(to: CGPoint(x: 668, y: 356))
        ridge.addLine(to: CGPoint(x: 930, y: 290))
        ridge.addLine(to: CGPoint(x: 930, y: 94))
        ridge.closeSubpath()
        context.setFillColor(CGColor(red: 0.08, green: 0.17, blue: 0.24, alpha: 1))
        context.addPath(ridge)
        context.fillPath()
        let doorway = CGMutablePath()
        doorway.move(to: CGPoint(x: 348, y: 244))
        doorway.addLine(to: CGPoint(x: 348, y: 494))
        doorway.addCurve(to: CGPoint(x: 674, y: 494), control1: CGPoint(x: 348, y: 730),
                         control2: CGPoint(x: 674, y: 730))
        doorway.addLine(to: CGPoint(x: 674, y: 244))
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 18,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
        context.setStrokeColor(CGColor(red: 0.90, green: 0.96, blue: 0.98, alpha: 1))
        context.setLineWidth(50)
        context.setLineCap(.round)
        context.addPath(doorway)
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        guard let image = context.makeImage() else { fatalError("Original icon rendering failed.") }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let url = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Cannot create original icon PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write original icon PNG.") }
    }
}
print("Generated ten original native app icon sizes.")
