import SwiftUI

/// «Приватность»: a glass shield filled with water, a raised hand on it and permission badges orbiting around.
extension SectionArt {
    private static func disc(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    }

    /// Shield outline in the 240×240 art space.
    private static var shieldPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 120, y: 26))
        path.addCurve(to: CGPoint(x: 196, y: 58), control1: CGPoint(x: 146, y: 44), control2: CGPoint(x: 170, y: 54))
        path.addCurve(to: CGPoint(x: 120, y: 214), control1: CGPoint(x: 198, y: 130), control2: CGPoint(x: 170, y: 186))
        path.addCurve(to: CGPoint(x: 44, y: 58), control1: CGPoint(x: 70, y: 186), control2: CGPoint(x: 42, y: 130))
        path.addCurve(to: CGPoint(x: 120, y: 26), control1: CGPoint(x: 70, y: 54), control2: CGPoint(x: 94, y: 44))
        path.closeSubpath()
        return path
    }

    static func drawShield(_ context: inout GraphicsContext, t: Double, spinning: Bool) {
        // Shadow under the shield.
        context.fill(Path(ellipseIn: CGRect(x: 48, y: 214, width: 144, height: 20)), with: .radialGradient(
            Gradient(colors: [.black.opacity(0.45), .black.opacity(0)]), center: CGPoint(x: 120, y: 224), startRadius: 0, endRadius: 72))

        // Badges on the far side of their orbit pass behind the shield.
        drawBadges(&context, t: t, spinning: spinning, front: false)

        let shield = shieldPath
        context.fill(shield, with: .linearGradient(
            Gradient(stops: [.init(color: Color(hex: 0xFFF7F6), location: 0), .init(color: Color(hex: 0xEBD3D2), location: 0.55),
                             .init(color: Color(hex: 0xB89495), location: 1)]),
            startPoint: CGPoint(x: 60, y: 30), endPoint: CGPoint(x: 150, y: 214)))

        // Inner glass with water that sways (and churns while loading).
        var inner = shield
        inner = inner.applying(CGAffineTransform(translationX: -120, y: -120).concatenating(CGAffineTransform(scaleX: 0.84, y: 0.84))
            .concatenating(CGAffineTransform(translationX: 120, y: 124)))
        context.fill(inner, with: .linearGradient(
            Gradient(colors: [Color(hex: 0x3F1F2B), Color(hex: 0x22111A)]), startPoint: CGPoint(x: 120, y: 40), endPoint: CGPoint(x: 120, y: 200)))
        context.drawLayer { layer in
            layer.clip(to: inner)
            let speed = spinning ? 0.9 : 3.2
            let shift = (t / speed).truncatingRemainder(dividingBy: 1) * 48
            let level = 128 + (spinning ? sin(t * 3) * 6 : sin(t * 0.8) * 3)
            for (index, (offset, color)) in [(-shift, Color(hex: 0xFF9C94).opacity(0.95)), (shift - 48, Color(hex: 0xC73A3E).opacity(0.55))].enumerated() {
                var wave = Path()
                let y = level + Double(index) * 7
                var x = 30 + offset
                wave.move(to: CGPoint(x: x, y: y))
                for step in 0..<8 {
                    wave.addQuadCurve(to: CGPoint(x: x + 24, y: y), control: CGPoint(x: x + 12, y: y + (step % 2 == 0 ? -7 : 7)))
                    x += 24
                }
                wave.addLine(to: CGPoint(x: x, y: 230))
                wave.addLine(to: CGPoint(x: 30 + offset, y: 230))
                wave.closeSubpath()
                layer.fill(wave, with: index == 0
                    ? .linearGradient(Gradient(colors: [color, Color(hex: 0x9E2A33)]), startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: 0, y: 214))
                    : .color(color))
            }
            // Bubbles rising through the water.
            for (index, (bx, r)) in [(92.0, 4.0), (138.0, 3.0), (116.0, 5.0), (150.0, 2.5)].enumerated() {
                let period = spinning ? 1.4 : 3.6
                let phase = ((t + Double(index) * 0.9).truncatingRemainder(dividingBy: period)) / period
                let y = 196 - phase * 60
                layer.stroke(disc(bx + sin(t * 2 + Double(index)) * 3, y, r), with: .color(.white.opacity(0.7 * (1 - phase))), lineWidth: 1.5)
            }
            // Glass highlight.
            layer.fill(Path(ellipseIn: CGRect(x: 66, y: 44, width: 60, height: 110)).applying(
                CGAffineTransform(translationX: -96, y: -99).concatenating(CGAffineTransform(rotationAngle: -0.35)).concatenating(CGAffineTransform(translationX: 96, y: 99))),
                with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(0)]), startPoint: CGPoint(x: 80, y: 44), endPoint: CGPoint(x: 110, y: 150)))
        }
        context.stroke(shield, with: .color(.white.opacity(0.85)), lineWidth: 1.5)

        // The raised hand of Privacy & Security.
        var hand = context.resolve(Image(systemName: "hand.raised.fill"))
        hand.shading = .color(.white.opacity(0.95))
        context.draw(hand, in: CGRect(x: 94, y: 74, width: 52, height: 58))

        drawBadges(&context, t: t, spinning: spinning, front: true)
    }

    /// Permission badges orbiting the shield: camera, microphone, folder.
    private static func drawBadges(_ context: inout GraphicsContext, t: Double, spinning: Bool, front: Bool) {
        let orbit = t * 2 * .pi / (spinning ? 3 : 16)
        let badges: [(String, Color)] = [("camera.fill", Color(hex: 0xFF7B72)), ("mic.fill", Color(hex: 0xFFB45E)), ("folder.fill", Color(hex: 0x62D2FF))]
        for (index, badge) in badges.enumerated() {
            let angle = orbit + Double(index) * 2 * .pi / Double(badges.count)
            guard (sin(angle) >= 0) == front else { continue }
            let x = 120 + cos(angle) * 100
            let y = 128 + sin(angle) * 34
            let r = 15 * (0.8 + 0.2 * (sin(angle) + 1) / 2)
            context.fill(disc(x, y + 2, r), with: .color(.black.opacity(0.25)))
            context.fill(disc(x, y, r), with: .linearGradient(
                Gradient(colors: [badge.1, badge.1.opacity(0.7)]), startPoint: CGPoint(x: x, y: y - r), endPoint: CGPoint(x: x, y: y + r)))
            context.stroke(disc(x, y, r), with: .color(.white.opacity(0.6)), lineWidth: 1)
            var icon = context.resolve(Image(systemName: badge.0))
            icon.shading = .color(.white)
            let size = r * 1.05
            context.draw(icon, in: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
        }
    }
}
