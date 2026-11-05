// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreGraphics
import SwiftUI

struct RenderedLabel {
    enum Style {
        case bodyMedium, calloutMedium, callout, caption, captionMedium, headline

        var font: Font {
            switch self {
            case .bodyMedium: .body.weight(.medium)
            case .calloutMedium: .callout.weight(.medium)
            case .callout: .callout
            case .caption: .caption
            case .captionMedium: .caption.weight(.medium)
            case .headline: .headline
            }
        }
    }

    enum Foreground {
        case primary, secondary

        var color: Color {
            switch self {
            case .primary: .primary
            case .secondary: .secondary
            }
        }
    }

    let text: String
    let style: Style
    let foreground: Foreground

    init(_ text: String, _ style: Style, foreground: Foreground = .secondary) {
        self.text = text
        self.style = style
        self.foreground = foreground
    }
}

enum RenderedLabelAppearance {
    case light, dark

    var scheme: ColorScheme { self == .light ? .light : .dark }
    var background: NSColor { self == .light ? .white : .black }
}

private struct LabelRaster {
    let width: Int
    let height: Int
    let ink: [Double]

    init(_ image: CGImage, appearance: RenderedLabelAppearance) throws {
        width = image.width
        height = image.height
        guard width > 1, height > 1 else { throw CocoaError(.coderInvalidValue) }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.coderInvalidValue)
        }
        context.setFillColor(appearance.background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let corners = [0, width - 1, (height - 1) * width, height * width - 1].map { index in
            let offset = index * 4
            return (Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])) / 3.0
        }
        guard let darkest = corners.min(), let brightest = corners.max(), brightest - darkest <= 2 else {
            throw CocoaError(.coderInvalidValue)
        }
        let background = corners.reduce(0, +) / Double(corners.count)
        ink = stride(from: 0, to: pixels.count, by: 4).map { offset in
            let value = (Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])) / 3.0
            return max(0, appearance == .light ? background - value : value - background)
        }
    }

    private init(width: Int, height: Int, ink: [Double]) {
        self.width = width
        self.height = height
        self.ink = ink
    }

    func cropped() throws -> LabelRaster {
        let points = ink.indices.filter { ink[$0] > 15 }
        guard let minX = points.map({ $0 % width }).min(),
              let maxX = points.map({ $0 % width }).max(),
              let minY = points.map({ $0 / width }).min(),
              let maxY = points.map({ $0 / width }).max() else {
            throw CocoaError(.coderInvalidValue)
        }
        return LabelRaster(width: maxX - minX + 1, height: maxY - minY + 1,
                           ink: (minY...maxY).flatMap { row in
                               (minX...maxX).map { col in ink[row * width + col] }
                           })
    }
}

private struct LabelMatch {
    let error: Double
    let maxDifference: Double
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

@MainActor
private func labelTemplate(_ label: RenderedLabel, phase: CGFloat, scale: CGFloat,
                           appearance: RenderedLabelAppearance) throws -> LabelRaster {
    let view = Text(verbatim: label.text)
        .font(label.style.font)
        .foregroundStyle(label.foreground.color)
        .fixedSize()
        .background(Color(nsColor: appearance.background))
        .environment(\.colorScheme, appearance.scheme)
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    var image: CGImage?
    renderer.render { size, draw in
        let width = Int(ceil(size.width * scale)) + 2
        let height = Int(ceil(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(appearance.background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: phase, y: 0)
        context.scaleBy(x: scale, y: scale)
        draw(context)
        image = context.makeImage()
    }
    guard let image else { throw CocoaError(.coderInvalidValue) }
    return try LabelRaster(image, appearance: appearance).cropped()
}

private func closestLabel(_ template: LabelRaster, in image: LabelRaster, within region: CGRect) -> LabelMatch? {
    let minX = Int(region.minX)
    let minY = Int(region.minY)
    let maxX = Int(region.maxX) - template.width
    let maxY = Int(region.maxY) - template.height
    guard maxX >= minX, maxY >= minY else { return nil }
    let foreground = template.ink.indices.filter { template.ink[$0] > 45 }
    guard foreground.count >= 12 else { return nil }
    let anchors = (0..<12).map { foreground[$0 * (foreground.count - 1) / 11] }
    let energy = template.ink.reduce(0) { $0 + $1 * $1 }
    var best: LabelMatch?
    for y in minY...maxY {
        for x in minX...maxX {
            if anchors.contains(where: {
                image.ink[(y + $0 / template.width) * image.width + x + $0 % template.width] < 15
            }) { continue }
            var dot = 0.0
            for row in 0..<template.height {
                for col in 0..<template.width {
                    dot += template.ink[row * template.width + col]
                        * image.ink[(y + row) * image.width + x + col]
                }
            }
            let scale = dot / energy
            if scale < 0.3 || scale > 2.0 { continue }
            var delta = 0.0
            var total = 0.0
            var maxDifference = 0.0
            for row in 0..<template.height {
                for col in 0..<template.width {
                    let expected = template.ink[row * template.width + col] * scale
                    let actual = image.ink[(y + row) * image.width + x + col]
                    let difference = abs(expected - actual)
                    delta += difference
                    total += expected + actual
                    maxDifference = max(maxDifference, difference)
                }
            }
            let error = delta / max(1, total)
            if error < (best?.error ?? .infinity) {
                best = LabelMatch(error: error, maxDifference: maxDifference,
                                  x: x, y: y, width: template.width, height: template.height)
            }
        }
    }
    return best
}

@MainActor
func renderedLabelFailures(_ bitmap: CGImage, _ labels: [RenderedLabel],
                           textRegion: CGRect? = nil, allowOtherInk: Bool = false,
                           appearance: RenderedLabelAppearance = .light,
                           scale: CGFloat = 1) throws -> [String] {
    guard scale.isFinite, scale > 0 else { throw CocoaError(.coderInvalidValue) }
    let image = try LabelRaster(bitmap, appearance: appearance)
    let region = (textRegion ?? CGRect(x: 0, y: 0, width: image.width, height: image.height))
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        .integral
    guard !region.isNull, !region.isEmpty else { throw CocoaError(.coderInvalidValue) }
    var covered = [Bool](repeating: false, count: image.ink.count)
    var previousY = -1
    var failures: [String] = []
    for label in labels {
        var best: LabelMatch?
        // SwiftUI can position a text run at a fractional pixel.
        for phase in 0..<8 {
            let template = try labelTemplate(label, phase: CGFloat(phase) / 8,
                                             scale: scale, appearance: appearance)
            if let match = closestLabel(template, in: image, within: region) {
                // An average alone can hide a changed character in a long label.
                let acceptable = match.error < 0.02 && match.maxDifference < 10
                let bestAcceptable = best.map { $0.error < 0.02 && $0.maxDifference < 10 } ?? false
                if (acceptable && !bestAcceptable)
                    || (acceptable == bestAcceptable && match.error < (best?.error ?? .infinity)) {
                    best = match
                }
                if acceptable && match.error < 0.008 { break }
            }
        }
        guard let match = best, match.error < 0.02, match.maxDifference < 10 else {
            failures.append("Missing or altered rendered label: \(label.text); "
                + "best error: \(best?.error ?? .infinity), pixel difference: \(best?.maxDifference ?? .infinity)")
            return failures
        }
        if match.y <= previousY {
            failures.append("Rendered labels are out of order: \(label.text)")
        }
        previousY = match.y
        for y in max(0, match.y - 1)..<min(image.height, match.y + match.height + 1) {
            for x in max(0, match.x - 1)..<min(image.width, match.x + match.width + 1) {
                covered[y * image.width + x] = true
            }
        }
    }
    guard !allowOtherInk else { return failures }
    var unexplained = 0
    for y in Int(region.minY)..<Int(region.maxY) {
        for x in Int(region.minX)..<Int(region.maxX) {
            let index = y * image.width + x
            if image.ink[index] > 15 && !covered[index] { unexplained += 1 }
        }
    }
    if unexplained != 0 {
        failures.append("Unexpected visible text or other ink in the tested region: \(unexplained) pixels")
    }
    return failures
}
