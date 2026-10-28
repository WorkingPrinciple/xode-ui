// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics

/// The original standalone X, shared by native views and the packaged icon renderer.
public enum XOdeMark {
    public static func path(in rect: CGRect) -> CGPath {
        let mark = CGMutablePath()
        mark.move(to: CGPoint(x: 7, y: 7))
        mark.addCurve(to: CGPoint(x: 106, y: 65), control1: CGPoint(x: 0, y: -4),
                      control2: CGPoint(x: 80, y: 20))
        mark.addCurve(to: CGPoint(x: 150, y: 100), control1: CGPoint(x: 117, y: 85),
                      control2: CGPoint(x: 131, y: 93))
        mark.addLine(to: CGPoint(x: 211, y: 189))
        mark.addQuadCurve(to: CGPoint(x: 199, y: 197), control: CGPoint(x: 222, y: 207))
        mark.addLine(to: CGPoint(x: 109, y: 130))
        mark.addLine(to: CGPoint(x: 18, y: 196))
        mark.addQuadCurve(to: CGPoint(x: 9, y: 190), control: CGPoint(x: 0, y: 208))
        mark.addLine(to: CGPoint(x: 61, y: 111))
        mark.addCurve(to: CGPoint(x: 59, y: 77), control1: CGPoint(x: 76, y: 91),
                      control2: CGPoint(x: 64, y: 88))
        mark.addLine(to: CGPoint(x: 7, y: 7))
        mark.closeSubpath()
        mark.move(to: CGPoint(x: 114, y: 52))
        mark.addCurve(to: CGPoint(x: 201, y: 8), control1: CGPoint(x: 139, y: 31),
                      control2: CGPoint(x: 171, y: 13))
        mark.addQuadCurve(to: CGPoint(x: 210, y: 15), control: CGPoint(x: 217, y: 2))
        mark.addLine(to: CGPoint(x: 152, y: 92))
        mark.addCurve(to: CGPoint(x: 114, y: 52), control1: CGPoint(x: 132, y: 86),
                      control2: CGPoint(x: 120, y: 71))
        mark.closeSubpath()
        let scale = min(rect.width / 220, rect.height / 210)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - 110 * scale,
                                           y: rect.midY - 105 * scale))
        let result = CGMutablePath()
        result.addPath(mark, transform: transform)
        return result
    }
}
