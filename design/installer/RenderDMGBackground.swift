// SPDX-License-Identifier: GPL-3.0-only
// Renders the X Ode disk-image background (original artwork) at 1x and 2x.
// swiftc Sources/OdeCore/XOdeMark.swift design/installer/RenderDMGBackground.swift -o /tmp/RenderDMGBackground
// /tmp/RenderDMGBackground design/installer
// Finder layout (points, top-left origin, window 660×400): app icon at (165, 190), Applications at (495, 190), icon size 128.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum DMGBackgroundRenderer {
    static let size = CGSize(width: 660, height: 400)
    static let appCenter = CGPoint(x: 165, y: 190)
    static let applicationsCenter = CGPoint(x: 495, y: 190)
    static let green = CGColor(red: 16 / 255, green: 124 / 255, blue: 16 / 255, alpha: 1)

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: RenderDMGBackground <output-directory>\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for scale in [1, 2] {
            let name = scale == 1 ? "dmg-background.png" : "dmg-background@2x.png"
            try write(render(scale: CGFloat(scale)), to: directory.appendingPathComponent(name))
        }
    }

    static func render(scale: CGFloat) -> CGImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Cannot allocate the background bitmap.")
        }
        context.scaleBy(x: scale, y: scale)
        // Flip so drawing uses Finder's top-left coordinates.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        // Soft, light neutral with a hint of the app's green; dark Finder labels stay readable.
        let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(red: 0.965, green: 0.975, blue: 0.965, alpha: 1),
            CGColor(red: 0.905, green: 0.935, blue: 0.910, alpha: 1)
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(background, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            green.copy(alpha: 0.10)!, green.copy(alpha: 0)!
        ] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: size.width / 2, y: 190), startRadius: 0,
                                   endCenter: CGPoint(x: size.width / 2, y: 190), endRadius: 300, options: [])

        // Lockup: the X mark with "Ode" beneath it, top centre.
        context.saveGState()
        context.addPath(XOdeMark.path(in: CGRect(x: size.width / 2 - 17, y: 26, width: 34, height: 32)))
        context.setFillColor(green)
        context.fillPath()
        context.restoreGState()
        drawText("Ode", size: 15, weight: 0.3, color: CGColor(gray: 0.15, alpha: 1),
                 center: CGPoint(x: size.width / 2, y: 74), in: context)

        // Arrow from the app to Applications.
        let start = CGPoint(x: appCenter.x + 88, y: appCenter.y), end = CGPoint(x: applicationsCenter.x - 92, y: appCenter.y)
        let arrow = CGMutablePath()
        arrow.move(to: start)
        arrow.addQuadCurve(to: CGPoint(x: end.x - 10, y: end.y - 3),
                           control: CGPoint(x: (start.x + end.x) / 2, y: appCenter.y - 34))
        context.addPath(arrow)
        context.setStrokeColor(green.copy(alpha: 0.75)!)
        context.setLineWidth(5)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [0.1, 12])
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        let head = CGMutablePath()
        head.move(to: CGPoint(x: end.x - 14, y: end.y - 14))
        head.addLine(to: end)
        head.addLine(to: CGPoint(x: end.x - 16, y: end.y + 9))
        context.addPath(head)
        context.setLineWidth(5)
        context.setLineJoin(.round)
        context.strokePath()

        drawText("Drag X Ode to Applications", size: 16, weight: 0.23, color: CGColor(gray: 0.2, alpha: 1),
                 center: CGPoint(x: size.width / 2, y: 340), in: context)
        return context.makeImage()!
    }

    static func drawText(_ string: String, size: CGFloat, weight: CGFloat, color: CGColor, center: CGPoint,
                         in context: CGContext) {
        let system = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(system),
                                                                  [kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.saveGState()
        // Undo the flip locally so glyphs aren't mirrored.
        context.translateBy(x: center.x - bounds.width / 2, y: center.y + bounds.height / 2 - 3)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * image.width / 660,
                                                        kCGImagePropertyDPIHeight: 72 * image.width / 660] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
