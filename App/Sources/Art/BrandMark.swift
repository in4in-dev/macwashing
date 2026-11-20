import SwiftUI

/// Sidebar logo: the washer mark plus the wordmark.
struct BrandLogo: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 9) {
            LiveWasherIcon()
                .frame(width: 26, height: 26)
            Text("\(Text("Mac").foregroundStyle(palette.muted).fontWeight(.regular))\(Text("Washing").foregroundStyle(palette.text).fontWeight(.semibold))")
                .font(.system(size: 16, design: .rounded))
                .kerning(-0.2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MacWashing")
    }
}

/// The washer mark with its water gently rolling (paused when the app is in the background).
struct LiveWasherIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsLive) private var animationsLive

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !animationsLive)) { timeline in
            WasherIcon(time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
        }
    }
}

/// The app's mark: the front of the washer from the System Junk page, squared up — a panel with lights and a
/// porthole with water and bubbles. The same for both themes; also the app icon (`margin` leaves the icon grid's
/// transparent border).
struct WasherIcon: View {
    var time: Double = 0
    var margin: Double = 0
    /// Height over width of the body (1 = square).
    var tall: Double = 1

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height / tall)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side * tall) / 2)
            let inset = side * margin
            context.translateBy(x: inset, y: inset)
            Self.draw(&context, unit: (side - inset * 2) / 100, t: time, shadow: margin > 0, tall: tall)
        }
        .aspectRatio(1 / tall, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// Draws on a 100 × 100·`tall` grid scaled by `unit`; the extra height goes around the porthole.
    static func draw(_ context: inout GraphicsContext, unit u: Double, t: Double, shadow: Bool, tall: Double = 1) {
        let bodyHeight = 100 * tall
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x * u, y: y * u, width: w * u, height: h * u) }
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * u, y: y * u) }
        func circle(_ x: Double, _ y: Double, _ r: Double) -> Path { Path(ellipseIn: rect(x - r, y - r, r * 2, r * 2)) }

        // Body.
        let body = Path(roundedRect: rect(0, 0, 100, bodyHeight), cornerRadius: 22.5 * u, style: .continuous)
        if shadow {
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.35), radius: 3 * u, x: 0, y: 1.5 * u))
            shadowed.fill(body, with: .color(Color(hex: 0xDCE4EC)))
        }
        context.fill(body, with: .linearGradient(
            Gradient(stops: [.init(color: Color(hex: 0xFAFCFE), location: 0), .init(color: Color(hex: 0xDCE4EC), location: 0.6),
                             .init(color: Color(hex: 0xAEBBC8), location: 1)]),
            startPoint: point(0, 0), endPoint: point(35, bodyHeight)))
        context.stroke(Path(roundedRect: rect(0.6, 0.6, 98.8, bodyHeight - 1.2), cornerRadius: 22 * u, style: .continuous),
                       with: .color(.white.opacity(0.8)), lineWidth: 1.2 * u)

        // Control panel.
        context.fill(Path(roundedRect: rect(13, 9, 74, 14), cornerRadius: 7 * u), with: .color(Color(hex: 0xE3E9EF)))
        context.fill(circle(21, 16, 3.4), with: .color(Color(hex: 0x4CCDE3)))
        context.fill(circle(31, 16, 3.4), with: .color(Color(hex: 0xBFCAD5)))
        context.fill(Path(roundedRect: rect(55, 13.5, 24, 5), cornerRadius: 2.5 * u), with: .color(Color(hex: 0xC9D3DD)))

        // Porthole.
        let center = (x: 50.0, y: 61.0 + (bodyHeight - 100) * 0.6)
        context.fill(circle(center.x, center.y, 32), with: .linearGradient(
            Gradient(stops: [.init(color: .white, location: 0), .init(color: Color(hex: 0xB3BECA), location: 0.5),
                             .init(color: Color(hex: 0x6A7686), location: 1)]),
            startPoint: point(18, center.y - 32), endPoint: point(82, center.y + 32)))
        context.fill(circle(center.x, center.y, 28), with: .color(Color(hex: 0x2E3643)))
        let glass = circle(center.x, center.y, 25.3)
        context.fill(glass, with: .radialGradient(
            Gradient(stops: [.init(color: Color(hex: 0xA8F5FF), location: 0), .init(color: Color(hex: 0x2FB6DA), location: 0.5),
                             .init(color: Color(hex: 0x0C4F7C), location: 1)]),
            center: point(43, center.y - 10), startRadius: 0, endRadius: 43 * u))

        context.drawLayer { inner in
            inner.clip(to: glass)
            let offsetA = (t / 3.4).truncatingRemainder(dividingBy: 1) * 21
            let offsetB = (t / 5.2).truncatingRemainder(dividingBy: 1) * 21
            inner.fill(wave(from: 18 - offsetA, y: center.y + 3, amplitude: 3.6, unit: u), with: .linearGradient(
                Gradient(colors: [Color(hex: 0x8BEBFF).opacity(0.95), Color(hex: 0x1478B2)]),
                startPoint: point(0, center.y - 1), endPoint: point(0, center.y + 35)))
            inner.fill(wave(from: -4 + offsetB, y: center.y + 7, amplitude: 2.7, unit: u), with: .color(Color(hex: 0x0E6FA8).opacity(0.45)))
            // Bubbles tumbling slowly with the drum.
            let angle = t * 2 * .pi / 22
            let bubbles: [(Double, Double, Double, Double)] = [
                (-10.7, 10.7, 3.1, 0.55), (8, 16.9, 2, 0.5), (13.8, 6.2, 4, 0.3), (-3.6, 20.4, 1.3, 0.6),
                (-15.1, -8, 1.8, 0.35), (11.6, -12.4, 2.4, 0.28), (-0.9, -16, 1.1, 0.5),
            ]
            for (dx, dy, r, alpha) in bubbles {
                let x = center.x + dx * cos(angle) - dy * sin(angle)
                let y = center.y + dx * sin(angle) + dy * cos(angle)
                inner.fill(circle(x, y, r), with: .color(.white.opacity(alpha)))
            }
        }

        var highlight = Path()
        highlight.addArc(center: point(center.x, center.y), radius: 20.4 * u, startAngle: .degrees(212), endAngle: .degrees(262), clockwise: false)
        context.stroke(highlight, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 3.1 * u, lineCap: .round))
        context.stroke(glass, with: .color(.white.opacity(0.35)), lineWidth: 0.9 * u)
    }

    private static func wave(from x0: Double, y: Double, amplitude: Double, unit u: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x0 * u, y: y * u))
        var x = x0
        for index in 0..<10 {
            let up = index % 2 == 0
            path.addQuadCurve(to: CGPoint(x: (x + 10.7) * u, y: y * u),
                              control: CGPoint(x: (x + 5.35) * u, y: (y + (up ? -amplitude : amplitude)) * u))
            x += 10.7
        }
        path.addLine(to: CGPoint(x: x * u, y: 140 * u))
        path.addLine(to: CGPoint(x: x0 * u, y: 140 * u))
        path.closeSubpath()
        return path
    }
}
