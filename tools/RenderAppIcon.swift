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
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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
                context.addPath(CGPath(roundedRect: CGRect(x: 94, y: 94, width: 836, height: 836),
                                       cornerWidth: 184, cornerHeight: 184, transform: nil))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillPath()
                // The shared mark uses native view coordinates, with positive Y down.
                context.translateBy(x: 0, y: 1024)
                context.scaleBy(x: 1, y: -1)
                context.addPath(XOdeMark.path(in: CGRect(x: 220, y: 232, width: 584, height: 560)))
                // Owner decision W1: the unchanged mark in burgundy #7A1E3A on the white tile (10.1:1).
                context.setFillColor(CGColor(red: 0x7A / 255, green: 0x1E / 255, blue: 0x3A / 255, alpha: 1))
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
