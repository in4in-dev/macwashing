import SwiftUI

/// «Автозапуск»: a glass panel of startup items whose switches flip one after another, and a power button floating
/// above it with water inside.
extension SectionArt {
    private static func pill(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: h / 2, style: .continuous)
    }

    static func drawPower(_ context: inout GraphicsContext, t: Double, spinning: Bool) {
        // Shadow under the panel.
        context.fill(Path(ellipseIn: CGRect(x: 30, y: 214, width: 180, height: 22)), with: .radialGradient(
            Gradient(colors: [.black.opacity(0.45), .black.opacity(0)]), center: CGPoint(x: 120, y: 225), startRadius: 0, endRadius: 90))

        // The glass panel.
        let panel = Path(roundedRect: CGRect(x: 28, y: 70, width: 184, height: 150), cornerRadius: 34, style: .continuous)
        context.fill(panel, with: .linearGradient(Gradient(colors: [.white.opacity(0.3), .white.opacity(0.06)]),
                                                  startPoint: CGPoint(x: 28, y: 70), endPoint: CGPoint(x: 90, y: 220)))
        context.stroke(Path(roundedRect: CGRect(x: 28.75, y: 70.75, width: 182.5, height: 148.5), cornerRadius: 33.25, style: .continuous),
                       with: .color(.white.opacity(0.4)), lineWidth: 1.5)

        // Three items: an icon tile, two text lines and a switch. The switches flip in turn (faster while loading).
        let tiles: [(UInt32, UInt32)] = [(0x9CC8FF, 0x3F7FE6), (0xFFD592, 0xEC8430), (0xA2EBB4, 0x2FA66A)]
        let period = spinning ? 1.6 : 4.8
        for (index, colors) in tiles.enumerated() {
            let y = 92 + Double(index) * 40
            let tile = Path(roundedRect: CGRect(x: 46, y: y, width: 26, height: 26), cornerRadius: 8, style: .continuous)
            context.fill(tile, with: .linearGradient(Gradient(colors: [Color(hex: colors.0), Color(hex: colors.1)]),
                                                     startPoint: CGPoint(x: 46, y: y), endPoint: CGPoint(x: 72, y: y + 26)))
            context.fill(pill(82, y + 5, 58 - Double(index) * 8, 6), with: .color(.white.opacity(0.75)))
            context.fill(pill(82, y + 16, 38, 5), with: .color(.white.opacity(0.35)))

            // 0…1 → the knob's travel, eased; each switch is a third of a period behind the one above.
            let phase = ((t / period + Double(index) / 3).truncatingRemainder(dividingBy: 1))
            let on = phase < 0.5
            let local = on ? phase / 0.5 : (phase - 0.5) / 0.5
            let travel = min(local / 0.12, 1)
            let eased = 1 - pow(1 - travel, 3)
            let position = on ? eased : 1 - eased
            let track = pill(154, y + 4, 38, 20)
            context.fill(track, with: .color(Color(hex: 0x82B6FF).opacity(0.25 + 0.7 * position)))
            context.stroke(track, with: .color(.white.opacity(0.35)), lineWidth: 1)
            let knobX = 156 + position * 18
            context.fill(Path(ellipseIn: CGRect(x: knobX, y: y + 6, width: 16, height: 16)).offsetBy(dx: 0, dy: 1),
                         with: .color(.black.opacity(0.2)))
            context.fill(Path(ellipseIn: CGRect(x: knobX, y: y + 6, width: 16, height: 16)), with: .color(.white))
        }

        // The power button above the panel: glass disc, water sloshing inside, the power glyph on top.
        let bob = sin(t * 2 * .pi / (spinning ? 1.2 : 3.6)) * 4
        let center = CGPoint(x: 120, y: 50 + bob)
        let radius = 36.0
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(Path(ellipseIn: CGRect(x: 88, y: 84, width: 64, height: 10)), with: .color(.black.opacity(0.14 - bob * 0.01)))
        context.fill(disc, with: .linearGradient(Gradient(colors: [Color(hex: 0x1D2B45), Color(hex: 0x111827)]),
                                                 startPoint: CGPoint(x: center.x, y: center.y - radius), endPoint: CGPoint(x: center.x, y: center.y + radius)))
        context.drawLayer { layer in
            layer.clip(to: disc)
            let shift = (t / (spinning ? 0.8 : 2.8)).truncatingRemainder(dividingBy: 1) * 48
            let level = center.y + 8 + (spinning ? sin(t * 3) * 4 : sin(t * 0.8) * 2)
            for (index, color) in [Color(hex: 0x9CC8FF).opacity(0.95), Color(hex: 0x3F7FE6).opacity(0.6)].enumerated() {
                var wave = Path()
                let y = level + Double(index) * 5
                var x = center.x - radius - 48 + (index == 0 ? -shift : shift - 48) + 48
                let start = x
                wave.move(to: CGPoint(x: x, y: y))
                for step in 0..<6 {
                    wave.addQuadCurve(to: CGPoint(x: x + 24, y: y), control: CGPoint(x: x + 12, y: y + (step % 2 == 0 ? -5 : 5)))
                    x += 24
                }
                wave.addLine(to: CGPoint(x: x, y: center.y + radius + 4))
                wave.addLine(to: CGPoint(x: start, y: center.y + radius + 4))
                wave.closeSubpath()
                layer.fill(wave, with: .color(color))
            }
            layer.fill(Path(ellipseIn: CGRect(x: center.x - 26, y: center.y - 30, width: 30, height: 22)),
                       with: .linearGradient(Gradient(colors: [.white.opacity(0.3), .white.opacity(0)]),
                                             startPoint: CGPoint(x: center.x - 20, y: center.y - 30), endPoint: CGPoint(x: center.x, y: center.y - 8)))
        }
        context.stroke(disc, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
        var glyph = context.resolve(Image(systemName: "power"))
        glyph.shading = .color(.white)
        context.draw(glyph, in: CGRect(x: center.x - 17, y: center.y - 19, width: 34, height: 36))
    }
}
