// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Original fictional environments, generated without external images or assets.
private let width = 2048
private let height = 1152
private let space = CGColorSpaceCreateDeviceRGB()

private struct Random {
    var state: UInt64
    mutating func value() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64.max >> 11)
    }
    mutating func between(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * value()
    }
}

private func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}

private func polygon(_ context: CGContext, _ points: [CGPoint], _ fill: CGColor) {
    guard let first = points.first else { return }
    context.beginPath()
    context.move(to: first)
    for point in points.dropFirst() { context.addLine(to: point) }
    context.closePath()
    context.setFillColor(fill)
    context.fillPath()
}

private func vertical(_ context: CGContext, _ colors: [CGColor], _ top: Double, _ bottom: Double) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top),
                               end: CGPoint(x: 0, y: bottom), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

private func glow(_ context: CGContext, _ center: CGPoint, _ radius: Double, _ fill: CGColor) {
    let transparent = fill.copy(alpha: 0)!
    let gradient = CGGradient(colorsSpace: space, colors: [fill, transparent] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
}

private func stroke(_ context: CGContext, _ points: [CGPoint], _ fill: CGColor, _ thickness: Double) {
    guard let first = points.first else { return }
    context.beginPath()
    context.move(to: first)
    for point in points.dropFirst() { context.addLine(to: point) }
    context.setStrokeColor(fill)
    context.setLineWidth(thickness)
    context.strokePath()
}

private func ridge(_ context: CGContext, _ random: inout Random, _ baseline: Double,
                   _ amplitude: Double, _ fill: CGColor) {
    var points = [CGPoint(x: -30, y: Double(height))]
    for index in 0...90 {
        let x = Double(index) * Double(width + 60) / 90 - 30
        let wave = sin(x / 270) * 0.3 + sin(x / 93) * 0.15
        points.append(CGPoint(x: x, y: baseline + amplitude * (wave + random.between(-0.25, 0.25))))
    }
    points.append(CGPoint(x: Double(width + 30), y: Double(height)))
    polygon(context, points, fill)
}

private func tree(_ context: CGContext, _ x: Double, _ base: Double, _ size: Double,
                  _ fill: CGColor, _ random: inout Random) {
    stroke(context, [CGPoint(x: x, y: base), CGPoint(x: x, y: base - size)], fill, max(1, size / 30))
    for tier in 0..<7 {
        let y = base - size + size * Double(tier) / 9
        let span = size * (0.065 + Double(tier) * 0.027)
        let skew = random.between(-0.025, 0.025) * size
        polygon(context, [
            CGPoint(x: x, y: y - size * 0.12),
            CGPoint(x: x - span, y: y + size * 0.13 + skew),
            CGPoint(x: x, y: y + size * 0.08),
            CGPoint(x: x + span, y: y + size * 0.1 - skew)
        ], fill)
    }
}

private func grain(_ context: CGContext, _ random: inout Random) {
    for _ in 0..<26000 {
        let alpha = random.between(0.006, 0.035)
        let tone = random.value() > 0.5 ? 1.0 : 0.0
        context.setFillColor(color(tone, tone, tone, alpha))
        context.fill(CGRect(x: random.between(0, Double(width)), y: random.between(0, Double(height)),
                            width: random.between(0.5, 1.5), height: random.between(0.5, 1.5)))
    }
}

private func harbor(_ context: CGContext) {
    var random = Random(state: 621718)
    vertical(context, [color(0.22, 0.24, 0.34), color(0.61, 0.37, 0.39),
                       color(0.93, 0.61, 0.42), color(0.27, 0.40, 0.45)], 0, 800)
    glow(context, CGPoint(x: 1450, y: 445), 650, color(1, 0.70, 0.43, 0.48))
    glow(context, CGPoint(x: 1440, y: 430), 175, color(1, 0.84, 0.64, 0.55))
    context.setFillColor(color(1, 0.88, 0.70))
    context.fillEllipse(in: CGRect(x: 1380, y: 365, width: 125, height: 125))

    for row in 0..<17 {
        let y = random.between(150, 460)
        let x = random.between(80, 1900)
        context.saveGState()
        context.translateBy(x: x, y: y)
        context.scaleBy(x: random.between(2.5, 5.5), y: 0.11)
        glow(context, .zero, random.between(35, 95), color(0.96, 0.69, 0.58, 0.05 + Double(row % 3) * 0.02))
        context.restoreGState()
    }
    ridge(context, &random, 630, 130, color(0.43, 0.40, 0.46))
    ridge(context, &random, 684, 110, color(0.28, 0.35, 0.40))
    context.saveGState()
    context.clip(to: CGRect(x: 0, y: 707, width: width, height: height - 707))
    vertical(context, [color(0.58, 0.51, 0.46), color(0.10, 0.27, 0.32)], 707, Double(height))
    for _ in 0..<175 {
        let y = random.between(710, 1152)
        let distance = (y - 710) / 442
        let x = 1440 + random.between(-1, 1) * (65 + distance * 310)
        let length = random.between(15, 80) * (0.3 + distance)
        stroke(context, [CGPoint(x: x, y: y), CGPoint(x: x + length, y: y)],
               color(1, 0.74, 0.50, random.between(0.04, 0.3)), random.between(1, 3))
    }
    for _ in 0..<240 {
        let x = random.between(0, 2048)
        let y = random.between(750, 1152)
        stroke(context, [CGPoint(x: x, y: y), CGPoint(x: x + random.between(10, 55), y: y)],
               color(0.72, 0.76, 0.75, 0.06), 1)
    }
    context.restoreGState()

    polygon(context, [CGPoint(x: 800, y: 746), CGPoint(x: 985, y: 548), CGPoint(x: 1160, y: 488),
                      CGPoint(x: 1240, y: 541), CGPoint(x: 1385, y: 587), CGPoint(x: 1460, y: 725)],
            color(0.27, 0.28, 0.31))
    polygon(context, [CGPoint(x: 910, y: 635), CGPoint(x: 1000, y: 550), CGPoint(x: 1160, y: 488),
                      CGPoint(x: 1240, y: 541), CGPoint(x: 1100, y: 606)], color(0.57, 0.40, 0.34))
    for _ in 0..<80 {
        let x = random.between(970, 1270)
        let y = random.between(595, 714)
        stroke(context, [CGPoint(x: x, y: y), CGPoint(x: x + random.between(15, 40), y: y + 9)],
               color(0.77, 0.56, 0.42, 0.13), 1)
    }
    // A distant port carved into the cliffs, not a borrowed game location.
    for index in 0..<12 {
        let x = 992 + Double(index) * 26
        let y = 585 + sin(Double(index) / 2) * 22
        context.setFillColor(color(0.23, 0.24, 0.28))
        context.fill(CGRect(x: x, y: y, width: 20, height: 45 + Double(index % 3) * 10))
        polygon(context, [CGPoint(x: x - 3, y: y), CGPoint(x: x + 10, y: y - 10),
                          CGPoint(x: x + 23, y: y)], color(0.37, 0.27, 0.27))
        context.setFillColor(color(1, 0.73, 0.45, 0.7))
        context.fill(CGRect(x: x + 9, y: y + 17, width: 3, height: 6))
    }
    stroke(context, [CGPoint(x: 1220, y: 670), CGPoint(x: 1410, y: 754)], color(0.23, 0.25, 0.27), 7)
    for index in 0..<9 {
        let x = 1230 + Double(index) * 22
        let y = 675 + Double(index) * 9.7
        stroke(context, [CGPoint(x: x, y: y), CGPoint(x: x, y: y + 40)], color(0.2, 0.24, 0.27), 4)
    }
    polygon(context, [CGPoint(x: 1550, y: 848), CGPoint(x: 1713, y: 844),
                      CGPoint(x: 1680, y: 880), CGPoint(x: 1588, y: 876)], color(0.12, 0.19, 0.23))
    stroke(context, [CGPoint(x: 1630, y: 855), CGPoint(x: 1630, y: 630)], color(0.11, 0.17, 0.20), 5)
    polygon(context, [CGPoint(x: 1633, y: 642), CGPoint(x: 1720, y: 818),
                      CGPoint(x: 1634, y: 813)], color(0.92, 0.74, 0.56))
    polygon(context, [CGPoint(x: 1624, y: 676), CGPoint(x: 1549, y: 808),
                      CGPoint(x: 1624, y: 811)], color(0.53, 0.47, 0.44))
    glow(context, CGPoint(x: 1100, y: 710), 280, color(0.9, 0.65, 0.43, 0.14))
    polygon(context, [CGPoint(x: 0, y: 880), CGPoint(x: 172, y: 815), CGPoint(x: 345, y: 934),
                      CGPoint(x: 442, y: 1046), CGPoint(x: 690, y: 1152), CGPoint(x: 0, y: 1152)],
            color(0.045, 0.12, 0.15))
    polygon(context, [CGPoint(x: 1770, y: 1152), CGPoint(x: 1900, y: 1050),
                      CGPoint(x: 2048, y: 998), CGPoint(x: 2048, y: 1152)], color(0.035, 0.09, 0.12))
    grain(context, &random)
}

private func orbit(_ context: CGContext) {
    var random = Random(state: 4700991)
    vertical(context, [color(0.025, 0.045, 0.10), color(0.12, 0.13, 0.26), color(0.31, 0.22, 0.30)], 0, 1100)
    for _ in 0..<90 {
        let x = random.between(800, 2200)
        let y = random.between(0, 700)
        glow(context, CGPoint(x: x, y: y), random.between(50, 230), color(0.35, 0.35, 0.66, 0.015))
    }
    for _ in 0..<1900 {
        let x = random.between(0, 2048)
        let y = random.between(0, 810)
        let radius = random.between(0.3, 1.15)
        context.setFillColor(color(0.72, 0.81, 1, random.between(0.18, 0.78)))
        context.fillEllipse(in: CGRect(x: x, y: y, width: radius * 2, height: radius * 2))
    }
    for _ in 0..<19 {
        let x = random.between(0, 2048), y = random.between(70, 600)
        glow(context, CGPoint(x: x, y: y), 10, color(0.68, 0.78, 1, 0.27))
        stroke(context, [CGPoint(x: x - 4, y: y), CGPoint(x: x + 4, y: y)], color(0.88, 0.91, 1, 0.7), 0.8)
        stroke(context, [CGPoint(x: x, y: y - 4), CGPoint(x: x, y: y + 4)], color(0.88, 0.91, 1, 0.7), 0.8)
    }
    let planet = CGRect(x: 1060, y: 58, width: 700, height: 700)
    glow(context, CGPoint(x: planet.midX, y: planet.midY), 445, color(0.19, 0.40, 0.73, 0.19))
    context.saveGState()
    context.addEllipse(in: planet)
    context.clip()
    vertical(context, [color(0.22, 0.54, 0.68), color(0.15, 0.28, 0.46), color(0.035, 0.08, 0.15)], 58, 758)
    for index in 0..<125 {
        let y = 70 + Double(index) * 5.5
        var points: [CGPoint] = []
        for x in stride(from: 1050.0, through: 1770, by: 12) {
            let displacement = sin(x / 85 + Double(index) * 0.26) * 14 + sin(x / 170) * 24
            points.append(CGPoint(x: x, y: y + displacement))
        }
        stroke(context, points, color(0.67, 0.77, 0.74, random.between(0.03, 0.20)),
               random.between(2, 13))
    }
    let shadow = CGGradient(colorsSpace: space, colors: [color(0, 0.02, 0.05, 0), color(0.01, 0.02, 0.05, 0.97)] as CFArray,
                            locations: [0, 1])!
    context.drawLinearGradient(shadow, start: CGPoint(x: 1160, y: 200), end: CGPoint(x: 1600, y: 630), options: [.drawsAfterEndLocation])
    glow(context, CGPoint(x: 1150, y: 140), 310, color(0.60, 0.86, 0.90, 0.28))
    context.restoreGState()
    context.saveGState()
    context.translateBy(x: 1410, y: 420)
    context.rotate(by: -0.28)
    context.setStrokeColor(color(0.76, 0.63, 0.62, 0.32))
    context.setLineWidth(16)
    context.strokeEllipse(in: CGRect(x: -570, y: -78, width: 1140, height: 156))
    context.setStrokeColor(color(0.86, 0.76, 0.74, 0.22))
    context.setLineWidth(5)
    context.strokeEllipse(in: CGRect(x: -594, y: -91, width: 1188, height: 182))
    context.restoreGState()
    glow(context, CGPoint(x: 650, y: 704), 340, color(0.61, 0.33, 0.33, 0.12))
    ridge(context, &random, 785, 150, color(0.31, 0.29, 0.40))
    ridge(context, &random, 897, 230, color(0.17, 0.19, 0.28))
    ridge(context, &random, 1088, 210, color(0.035, 0.07, 0.13))
    for index in 0..<35 {
        let y = 865 + Double(index) * 8
        stroke(context, [CGPoint(x: random.between(0, 900), y: y),
                         CGPoint(x: random.between(920, 2000), y: y + random.between(-16, 8))],
               color(0.45, 0.39, 0.47, 0.075), 1)
    }
    // Small original explorer and beacon give the imagined landscape scale.
    context.setFillColor(color(0.03, 0.06, 0.11))
    context.fillEllipse(in: CGRect(x: 1528, y: 873, width: 11, height: 11))
    polygon(context, [CGPoint(x: 1526, y: 884), CGPoint(x: 1540, y: 884),
                      CGPoint(x: 1545, y: 916), CGPoint(x: 1522, y: 916)], color(0.03, 0.06, 0.11))
    stroke(context, [CGPoint(x: 1527, y: 911), CGPoint(x: 1525, y: 932)], color(0.03, 0.06, 0.11), 5)
    stroke(context, [CGPoint(x: 1537, y: 911), CGPoint(x: 1541, y: 932)], color(0.03, 0.06, 0.11), 5)
    stroke(context, [CGPoint(x: 1660, y: 934), CGPoint(x: 1660, y: 902)], color(0.31, 0.42, 0.50), 3)
    glow(context, CGPoint(x: 1660, y: 903), 19, color(1, 0.54, 0.36, 0.7))
    grain(context, &random)
}

private func alpine(_ context: CGContext) {
    var random = Random(state: 955196)
    vertical(context, [color(0.12, 0.27, 0.36), color(0.52, 0.69, 0.71),
                       color(0.80, 0.73, 0.64)], 0, 850)
    glow(context, CGPoint(x: 1660, y: 285), 420, color(1, 0.85, 0.63, 0.27))
    for layer in 0..<4 {
        let base = 670 + Double(layer) * 75
        let offset = Double(layer) * 73
        let peak = 1120 + offset
        let points = [
            CGPoint(x: -80, y: base + 90), CGPoint(x: 110, y: base - 30),
            CGPoint(x: 390, y: base - 180), CGPoint(x: 630, y: base - 105),
            CGPoint(x: peak - 290, y: base - 350), CGPoint(x: peak - 150, y: base - 290),
            CGPoint(x: peak, y: base - 590 + Double(layer) * 42),
            CGPoint(x: peak + 110, y: base - 445), CGPoint(x: peak + 205, y: base - 505),
            CGPoint(x: peak + 470, y: base - 240), CGPoint(x: 2120, y: base + 60),
            CGPoint(x: 2120, y: 1152), CGPoint(x: -80, y: 1152)
        ]
        let value = 0.44 - Double(layer) * 0.065
        polygon(context, points, color(value, value + 0.11, value + 0.14))
        if layer < 3 {
            polygon(context, [CGPoint(x: peak - 290, y: base - 350),
                              CGPoint(x: peak - 150, y: base - 290),
                              CGPoint(x: peak, y: base - 590 + Double(layer) * 42),
                              CGPoint(x: peak - 52, y: base - 260),
                              CGPoint(x: peak - 120, y: base - 215)],
                    color(0.85 - Double(layer) * 0.11, 0.87 - Double(layer) * 0.08, 0.85 - Double(layer) * 0.06))
            polygon(context, [CGPoint(x: peak, y: base - 590 + Double(layer) * 42),
                              CGPoint(x: peak + 110, y: base - 445),
                              CGPoint(x: peak + 205, y: base - 505),
                              CGPoint(x: peak + 285, y: base - 415),
                              CGPoint(x: peak + 175, y: base - 342),
                              CGPoint(x: peak + 83, y: base - 405)],
                    color(0.71 - Double(layer) * 0.10, 0.80 - Double(layer) * 0.08, 0.81 - Double(layer) * 0.06))
            for _ in 0..<45 {
                let x = random.between(peak - 200, peak + 220)
                let y = random.between(base - 380, base - 180)
                stroke(context, [CGPoint(x: x, y: y), CGPoint(x: x - 25, y: y + 80)],
                       color(0.13, 0.25, 0.31, 0.09), random.between(1, 5))
            }
        }
    }
    context.saveGState()
    context.clip(to: CGRect(x: 0, y: 895, width: width, height: height - 895))
    vertical(context, [color(0.37, 0.62, 0.65), color(0.10, 0.25, 0.33)], 895, 1152)
    for _ in 0..<300 {
        let x = random.between(250, 1860)
        let y = random.between(900, 1152)
        stroke(context, [CGPoint(x: x, y: y), CGPoint(x: x + random.between(12, 40), y: y)],
               color(0.73, 0.83, 0.79, 0.06), 1)
    }
    context.restoreGState()
    for index in 0..<100 {
        let x = Double(index) * 21 + random.between(-7, 7)
        let base = 918 + sin(x / 135) * 19
        tree(context, x, base, random.between(25, 72), color(0.16, 0.32, 0.34), &random)
    }
    context.saveGState()
    context.translateBy(x: 960, y: 907)
    context.scaleBy(x: 5.5, y: 0.3)
    glow(context, .zero, 230, color(0.75, 0.83, 0.79, 0.2))
    context.restoreGState()
    polygon(context, [CGPoint(x: 0, y: 1020), CGPoint(x: 180, y: 1050), CGPoint(x: 470, y: 1152),
                      CGPoint(x: 0, y: 1152)], color(0.055, 0.15, 0.19))
    polygon(context, [CGPoint(x: 1640, y: 1152), CGPoint(x: 1790, y: 1040),
                      CGPoint(x: 2048, y: 960), CGPoint(x: 2048, y: 1152)], color(0.055, 0.15, 0.19))
    for index in 0..<12 {
        let x = 20 + Double(index) * 22
        tree(context, x, 1125 + Double(index) * 3, random.between(160, 270),
             color(0.035, 0.11, 0.15), &random)
    }
    for index in 0..<9 {
        let x = 1850 + Double(index) * 24
        tree(context, x, 1060 + random.between(-10, 45), random.between(190, 320),
             color(0.035, 0.11, 0.15), &random)
    }
    grain(context, &random)
}

private func render(_ name: String, into directory: URL, draw: (CGContext) -> Void) throws {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "OriginalArt", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create art context"])
    }
    context.setShouldAntialias(true)
    context.translateBy(x: 0, y: Double(height))
    context.scaleBy(x: 1, y: -1)
    draw(context)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name + ".png") as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "OriginalArt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode art"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "OriginalArt", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot write art"])
    }
    print("\(name).png \(width)x\(height), original generated environment")
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "OriginalArt", code: 4, userInfo: [NSLocalizedDescriptionKey: "Pass an output directory"])
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try render("harbor", into: output, draw: harbor)
    try render("orbit", into: output, draw: orbit)
    try render("ridge", into: output, draw: alpine)
} catch {
    FileHandle.standardError.write(Data("Original art render failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
