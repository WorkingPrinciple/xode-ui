// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics

/// The Ode crossed-swords mark: downward-pointing crossed blades with a compact crossguard
/// and a negative-space knockout gap at the crossing point.
public enum XOdeMark {
    public static func path(in rect: CGRect) -> CGPath {
        let result = CGMutablePath()

        // Single sword components in local coordinates centered around crossing origin (0, 0)
        let hilt = CGMutablePath()
        hilt.addEllipse(in: CGRect(x: -4.5, y: -50.5, width: 9, height: 9))
        hilt.addRoundedRect(in: CGRect(x: -2.5, y: -41.5, width: 5, height: 13), cornerWidth: 1.5, cornerHeight: 1.5)
        hilt.addRoundedRect(in: CGRect(x: -10.5, y: -28.5, width: 21, height: 4.5), cornerWidth: 2, cornerHeight: 2)

        let fgBlade = CGMutablePath()
        fgBlade.move(to: CGPoint(x: -4.5, y: -24))
        fgBlade.addLine(to: CGPoint(x: 4.5, y: -24))
        fgBlade.addLine(to: CGPoint(x: 4.5, y: 38))
        fgBlade.addLine(to: CGPoint(x: 0, y: 53))
        fgBlade.addLine(to: CGPoint(x: -4.5, y: 38))
        fgBlade.closeSubpath()

        let bgUpper = CGMutablePath()
        bgUpper.move(to: CGPoint(x: -4.5, y: -24))
        bgUpper.addLine(to: CGPoint(x: 4.5, y: -24))
        bgUpper.addLine(to: CGPoint(x: 4.5, y: -8.5))
        bgUpper.addLine(to: CGPoint(x: -4.5, y: -8.5))
        bgUpper.closeSubpath()

        let bgLower = CGMutablePath()
        bgLower.move(to: CGPoint(x: -4.5, y: 8.5))
        bgLower.addLine(to: CGPoint(x: 4.5, y: 8.5))
        bgLower.addLine(to: CGPoint(x: 4.5, y: 38))
        bgLower.addLine(to: CGPoint(x: 0, y: 53))
        bgLower.addLine(to: CGPoint(x: -4.5, y: 38))
        bgLower.closeSubpath()

        // Combined model
        let model = CGMutablePath()
        let rotRight = CGAffineTransform(rotationAngle: .pi / 4)
        let rotLeft = CGAffineTransform(rotationAngle: -.pi / 4)

        // Background sword (tilted left, with gap at the crossing)
        model.addPath(hilt, transform: rotLeft)
        model.addPath(bgUpper, transform: rotLeft)
        model.addPath(bgLower, transform: rotLeft)

        // Foreground sword (tilted right, uninterrupted)
        model.addPath(hilt, transform: rotRight)
        model.addPath(fgBlade, transform: rotRight)

        let box = model.boundingBoxOfPath
        let scale = min(rect.width / box.width, rect.height / box.height) * 0.95
        let transform = CGAffineTransform(translationX: -box.midX, y: -box.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))

        result.addPath(model, transform: transform)
        return result
    }
}
