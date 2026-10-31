// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum AppIconRenderer {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: RenderAppIcon <explicit-iconset-directory>\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                              bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    fatalError("Cannot allocate Ode icon bitmap.")
                }
                context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

                // Rounded tile
                let tilePath = CGPath(roundedRect: CGRect(x: 94, y: 94, width: 836, height: 836),
                                      cornerWidth: 184, cornerHeight: 184, transform: nil)

                // Wine gradient tile (#85223E -> #4A1022)
                context.saveGState()
                context.addPath(tilePath)
                context.clip()
                let wineColors = [
                    CGColor(srgbRed: 133 / 255, green: 34 / 255, blue: 62 / 255, alpha: 1),
                    CGColor(srgbRed: 74 / 255, green: 16 / 255, blue: 34 / 255, alpha: 1)
                ] as CFArray
                if let gradient = CGGradient(colorsSpace: colorSpace, colors: wineColors, locations: [0, 1]) {
                    context.drawLinearGradient(gradient, start: CGPoint(x: 94, y: 94), end: CGPoint(x: 930, y: 930), options: [])
                }
                context.restoreGState()

                // Subtle rim border
                context.addPath(tilePath)
                context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
                context.setLineWidth(4)
                context.strokePath()

                // The shared mark uses native view coordinates, with positive Y down.
                context.translateBy(x: 0, y: 1024)
                context.scaleBy(x: 1, y: -1)
                context.addPath(XOdeMark.path(in: CGRect(x: 216, y: 216, width: 592, height: 592)))
                // Ochre mark: #F4C77A
                context.setFillColor(CGColor(srgbRed: 244 / 255, green: 199 / 255, blue: 122 / 255, alpha: 1))
                context.fillPath()

                guard let image = context.makeImage() else { fatalError("Ode icon rendering failed.") }
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                let url = directory.appendingPathComponent(name)
                guard let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    fatalError("Cannot create Ode icon PNG.")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write Ode icon PNG.") }
            }
        }
        print("Generated ten native Ode app icon sizes from the shared X mark.")
    }
}
