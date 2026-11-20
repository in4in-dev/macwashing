import SwiftUI

/// Animated illustrations of the sections, drawn in a 240×240 space.
struct SectionArt: View {
    enum Kind { case washer, folder, apps, shield, power, done }

    let kind: Kind
    var spinning = false
    var size: CGFloat = 300

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsLive) private var animationsLive
    @State private var appeared = Date()

    var body: some View {
        // Full rate while something is happening, a calm 30 fps at rest; paused in the background.
        TimelineView(.animation(minimumInterval: spinning ? 1 / 60 : 1 / 30, paused: reduceMotion || !animationsLive)) { timeline in
            let t = reduceMotion ? 10 : timeline.date.timeIntervalSince(appeared)
            Canvas { context, canvasSize in
                let s = canvasSize.width / 240
                context.scaleBy(x: s, y: s)
                switch kind {
                case .washer: Self.drawWasher(&context, t: t, spinning: spinning)
                case .folder: Self.drawFolder(&context, t: t, spinning: spinning)
                case .apps: Self.drawApps(&context, t: t, spinning: spinning)
                case .shield: Self.drawShield(&context, t: t, spinning: spinning)
                case .power: Self.drawPower(&context, t: t, spinning: spinning)
                case .done: Self.drawDone(&context, t: t)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { appeared = Date() }
        .accessibilityHidden(true)
    }

    // MARK: Helpers

    private static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    private static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
        ellipse(cx, cy, r, r)
    }

    private static func shadow(_ context: inout GraphicsContext, cx: Double, cy: Double, rx: Double, ry: Double) {
        context.fill(ellipse(cx, cy, rx, ry), with: .radialGradient(
            Gradient(colors: [.black.opacity(0.5), .black.opacity(0)]),
            center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: rx))
    }

    private static func wave(from x0: Double, y: Double, amplitude: Double, periods: Int, bottom: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x0, y: y))
        var x = x0
        for index in 0..<(periods * 2) {
            let up = index % 2 == 0
            path.addQuadCurve(to: CGPoint(x: x + 24, y: y), control: CGPoint(x: x + 12, y: y + (up ? -amplitude : amplitude)))
            x += 24
        }
        path.addLine(to: CGPoint(x: x, y: bottom))
        path.addLine(to: CGPoint(x: x0, y: bottom))
        path.closeSubpath()
        return path
    }

    /// Bubble that rises and fades on a loop.
    private static func risingBubble(_ context: inout GraphicsContext, x: Double, y: Double, r: Double, t: Double, period: Double, delay: Double, color: Color) {
        let phase = ((t - delay).truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
        let rise = phase * 70
        let alpha = phase < 0.15 ? phase / 0.15 : 1 - (phase - 0.15) / 0.85
        context.stroke(circle(x, y - rise, r * (0.8 + phase * 0.3)), with: .color(color.opacity(0.8 * alpha)), lineWidth: 2)
    }

    // MARK: Washer

    static func drawWasher(_ context: inout GraphicsContext, t: Double, spinning: Bool) {
        shadow(&context, cx: 120, cy: 224, rx: 92, ry: 12)
        let body = Path(roundedRect: CGRect(x: 36, y: 20, width: 168, height: 198), cornerRadius: 36, style: .continuous)
        context.fill(body, with: .linearGradient(
            Gradient(stops: [.init(color: Color(hex: 0xFAFCFE), location: 0), .init(color: Color(hex: 0xDCE4EC), location: 0.6), .init(color: Color(hex: 0xAEBBC8), location: 1)]),
            startPoint: CGPoint(x: 36, y: 20), endPoint: CGPoint(x: 95, y: 218)))
        context.stroke(Path(roundedRect: CGRect(x: 36.75, y: 20.75, width: 166.5, height: 196.5), cornerRadius: 35.25, style: .continuous),
                       with: .color(.white.opacity(0.8)), lineWidth: 1.5)
        context.fill(Path(roundedRect: CGRect(x: 54, y: 36, width: 132, height: 26), cornerRadius: 13), with: .color(Color(hex: 0xE3E9EF)))
        let blink = spinning ? 0.35 + 0.65 * (0.5 + 0.5 * cos(t * 2 * .pi)) : 1
        context.fill(circle(70, 49, 6), with: .color(Color(hex: 0x4CCDE3).opacity(blink)))
        context.fill(circle(90, 49, 6), with: .color(Color(hex: 0xBFCAD5)))
        context.fill(Path(roundedRect: CGRect(x: 130, y: 44, width: 42, height: 10), cornerRadius: 5), with: .color(Color(hex: 0xC9D3DD)))

        context.fill(circle(120, 136, 72), with: .linearGradient(
            Gradient(stops: [.init(color: .white, location: 0), .init(color: Color(hex: 0xB3BECA), location: 0.5), .init(color: Color(hex: 0x6A7686), location: 1)]),
            startPoint: CGPoint(x: 48, y: 64), endPoint: CGPoint(x: 192, y: 208)))
        context.fill(circle(120, 136, 63), with: .color(Color(hex: 0x2E3643)))
        let glass = circle(120, 136, 57)
        context.fill(glass, with: .radialGradient(
            Gradient(stops: [.init(color: Color(hex: 0xA8F5FF), location: 0), .init(color: Color(hex: 0x2FB6DA), location: 0.5), .init(color: Color(hex: 0x0C4F7C), location: 1)]),
            center: CGPoint(x: 104, y: 113), startRadius: 0, endRadius: 97))

        context.drawLayer { inner in
            inner.clip(to: glass)
            let speedA = spinning ? 1.1 : 3.4, speedB = spinning ? 1.6 : 5.2
            let offsetA = (t / speedA).truncatingRemainder(dividingBy: 1) * 48
            let offsetB = (t / speedB).truncatingRemainder(dividingBy: 1) * 48
            inner.fill(wave(from: 40 - offsetA, y: 142, amplitude: 8, periods: 5, bottom: 214), with: .linearGradient(
                Gradient(colors: [Color(hex: 0x8BEBFF).opacity(0.95), Color(hex: 0x1478B2)]),
                startPoint: CGPoint(x: 0, y: 134), endPoint: CGPoint(x: 0, y: 214)))
            inner.fill(wave(from: -8 + offsetB, y: 150, amplitude: 6, periods: 5, bottom: 214), with: .color(Color(hex: 0x0E6FA8).opacity(0.45)))

            // Bubbles tumbling with the drum.
            let angle = t * 2 * .pi / (spinning ? 1.4 : 22)
            let bubbles: [(Double, Double, Double, Double)] = [
                (-24, 24, 7, 0.55), (18, 38, 4.5, 0.5), (31, 14, 9, 0.3), (-8, 46, 3, 0.6),
                (-34, -18, 4, 0.35), (26, -28, 5.5, 0.28), (-2, -36, 2.5, 0.5),
            ]
            for (dx, dy, r, alpha) in bubbles {
                let x = 120 + dx * cos(angle) - dy * sin(angle)
                let y = 136 + dx * sin(angle) + dy * cos(angle)
                inner.fill(circle(x, y, r), with: .color(.white.opacity(alpha)))
            }
        }

        var highlight = Path()
        highlight.addArc(center: CGPoint(x: 120, y: 136), radius: 46, startAngle: .degrees(212), endAngle: .degrees(262), clockwise: false)
        context.stroke(highlight, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        context.stroke(circle(120, 136, 57), with: .color(.white.opacity(0.35)), lineWidth: 2)

        let ring = Color(hex: 0x9FF0FF)
        if spinning {
            risingBubble(&context, x: 206, y: 40, r: 11, t: t, period: 2.2, delay: 0, color: ring)
            risingBubble(&context, x: 222, y: 72, r: 5, t: t, period: 2.6, delay: 0.6, color: ring)
            risingBubble(&context, x: 22, y: 108, r: 7, t: t, period: 2.4, delay: 1.2, color: ring)
        } else {
            let bob = { (period: Double, delay: Double) in sin((t + delay) * 2 * .pi / period) * 5 }
            context.stroke(circle(206, 30 + bob(4, 0), 11), with: .color(ring.opacity(0.75)), lineWidth: 2)
            context.stroke(circle(222, 62 + bob(5, 0.8), 5), with: .color(ring.opacity(0.6)), lineWidth: 2)
            context.stroke(circle(22, 98 + bob(4.6, 1.6), 7), with: .color(ring.opacity(0.55)), lineWidth: 2)
        }
    }

    // MARK: Folder

    static func drawFolder(_ context: inout GraphicsContext, t: Double, spinning: Bool) {
        shadow(&context, cx: 120, cy: 222, rx: 96, ry: 13)
        var back = Path()
        back.move(to: CGPoint(x: 40, y: 46))
        back.addLine(to: CGPoint(x: 84, y: 46))
        back.addQuadCurve(to: CGPoint(x: 94.2, y: 50.4), control: CGPoint(x: 90, y: 46))
        back.addLine(to: CGPoint(x: 106, y: 62))
        back.addLine(to: CGPoint(x: 200, y: 62))
        back.addQuadCurve(to: CGPoint(x: 214, y: 76), control: CGPoint(x: 214, y: 62))
        back.addLine(to: CGPoint(x: 214, y: 192))
        back.addQuadCurve(to: CGPoint(x: 200, y: 206), control: CGPoint(x: 214, y: 206))
        back.addLine(to: CGPoint(x: 40, y: 206))
        back.addQuadCurve(to: CGPoint(x: 26, y: 192), control: CGPoint(x: 26, y: 206))
        back.addLine(to: CGPoint(x: 26, y: 60))
        back.addQuadCurve(to: CGPoint(x: 40, y: 46), control: CGPoint(x: 26, y: 46))
        context.fill(back, with: .linearGradient(Gradient(colors: [Color(hex: 0xFFC878), Color(hex: 0xD96E24)]),
                                                 startPoint: CGPoint(x: 0, y: 46), endPoint: CGPoint(x: 0, y: 206)))

        let paper = GraphicsContext.Shading.linearGradient(Gradient(colors: [.white, Color(hex: 0xDCE3EA)]),
                                                           startPoint: CGPoint(x: 0, y: 26), endPoint: CGPoint(x: 0, y: 164))
        context.drawLayer { layer in
            layer.opacity = 0.8
            layer.translateBy(x: 97, y: 92)
            layer.rotate(by: .degrees(-10))
            layer.translateBy(x: -97, y: -92)
            layer.fill(Path(roundedRect: CGRect(x: 56, y: 38, width: 82, height: 108), cornerRadius: 12), with: paper)
        }
        let bob = sin(t * 2 * .pi / (spinning ? 1.6 : 5)) * 5
        context.drawLayer { layer in
            layer.translateBy(x: 0, y: bob)
            layer.translateBy(x: 131, y: 95)
            layer.rotate(by: .degrees(8))
            layer.translateBy(x: -131, y: -95)
            var doc = Path()
            doc.move(to: CGPoint(x: 98, y: 26))
            doc.addLine(to: CGPoint(x: 148, y: 26))
            doc.addLine(to: CGPoint(x: 176, y: 54))
            doc.addLine(to: CGPoint(x: 176, y: 152))
            doc.addQuadCurve(to: CGPoint(x: 164, y: 164), control: CGPoint(x: 176, y: 164))
            doc.addLine(to: CGPoint(x: 98, y: 164))
            doc.addQuadCurve(to: CGPoint(x: 86, y: 152), control: CGPoint(x: 86, y: 164))
            doc.addLine(to: CGPoint(x: 86, y: 38))
            doc.addQuadCurve(to: CGPoint(x: 98, y: 26), control: CGPoint(x: 86, y: 26))
            layer.fill(doc, with: paper)
            var ear = Path()
            ear.move(to: CGPoint(x: 148, y: 26))
            ear.addLine(to: CGPoint(x: 148, y: 44))
            ear.addQuadCurve(to: CGPoint(x: 158, y: 54), control: CGPoint(x: 148, y: 54))
            ear.addLine(to: CGPoint(x: 176, y: 54))
            layer.fill(ear, with: .color(Color(hex: 0xC7D1DB)))
            for (y, w, c) in [(76.0, 56.0, 0xC3CDD8), (92, 44, 0xD3DBE3), (108, 50, 0xD3DBE3)] as [(Double, Double, UInt32)] {
                layer.fill(Path(roundedRect: CGRect(x: 102, y: y, width: w, height: 8), cornerRadius: 4), with: .color(Color(hex: c)))
            }
        }

        var front = Path()
        front.move(to: CGPoint(x: 34, y: 90))
        front.addLine(to: CGPoint(x: 206, y: 90))
        front.addQuadCurve(to: CGPoint(x: 220, y: 104), control: CGPoint(x: 220, y: 90))
        front.addLine(to: CGPoint(x: 213, y: 192))
        front.addQuadCurve(to: CGPoint(x: 199, y: 205), control: CGPoint(x: 212, y: 205))
        front.addLine(to: CGPoint(x: 41, y: 205))
        front.addQuadCurve(to: CGPoint(x: 27, y: 192), control: CGPoint(x: 28, y: 205))
        front.addLine(to: CGPoint(x: 20, y: 104))
        front.addQuadCurve(to: CGPoint(x: 34, y: 90), control: CGPoint(x: 20, y: 90))
        context.fill(front, with: .linearGradient(Gradient(colors: [Color(hex: 0xFFE3AE).opacity(0.97), Color(hex: 0xFFA040).opacity(0.97)]),
                                                  startPoint: CGPoint(x: 0, y: 90), endPoint: CGPoint(x: 30, y: 205)))
        var edge = Path()
        edge.move(to: CGPoint(x: 34, y: 90.8))
        edge.addLine(to: CGPoint(x: 206, y: 90.8))
        context.stroke(edge, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        context.fill(Path(roundedRect: CGRect(x: 44, y: 150, width: 76, height: 28), cornerRadius: 14), with: .color(.white.opacity(0.92)))
        for (x, w) in [(56.0, 30.0), (92, 16)] {
            context.fill(Path(roundedRect: CGRect(x: x, y: 161, width: w, height: 6), cornerRadius: 3), with: .color(Color(hex: 0xE9A25C)))
        }

        // Magnifier: sweeps while scanning.
        let phase = t * 2 * .pi / 2.2
        let dx = spinning ? sin(phase) * 11 : 0, dy = spinning ? sin(phase * 2) * 6 : 0
        let tilt = spinning ? sin(phase) * 6 : 0
        context.drawLayer { layer in
            layer.translateBy(x: dx, y: dy)
            layer.translateBy(x: 186, y: 172)
            layer.rotate(by: .degrees(tilt))
            layer.translateBy(x: -186, y: -172)
            let lens = circle(174, 160, 25)
            layer.fill(lens, with: .linearGradient(Gradient(colors: [.white.opacity(0.8), .white.opacity(0.12)]),
                                                   startPoint: CGPoint(x: 150, y: 136), endPoint: CGPoint(x: 198, y: 184)))
            layer.stroke(lens, with: .color(.white), lineWidth: 6)
            var handle = Path()
            handle.move(to: CGPoint(x: 192, y: 178))
            handle.addLine(to: CGPoint(x: 209, y: 195))
            layer.stroke(handle, with: .color(.white), style: StrokeStyle(lineWidth: 10, lineCap: .round))
            var glint = Path()
            glint.addArc(center: CGPoint(x: 174, y: 160), radius: 14, startAngle: .degrees(200), endAngle: .degrees(250), clockwise: false)
            layer.stroke(glint, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }

    // MARK: Apps

    static func drawApps(_ context: inout GraphicsContext, t: Double, spinning: Bool) {
        shadow(&context, cx: 120, cy: 226, rx: 94, ry: 12)
        let plate = Path(roundedRect: CGRect(x: 30, y: 52, width: 180, height: 168), cornerRadius: 42, style: .continuous)
        context.fill(plate, with: .linearGradient(Gradient(colors: [.white.opacity(0.3), .white.opacity(0.06)]),
                                                  startPoint: CGPoint(x: 30, y: 52), endPoint: CGPoint(x: 80, y: 220)))
        context.stroke(Path(roundedRect: CGRect(x: 30.75, y: 52.75, width: 178.5, height: 166.5), cornerRadius: 41.25, style: .continuous),
                       with: .color(.white.opacity(0.4)), lineWidth: 1.5)

        func tile(_ x: Double, _ y: Double, _ a: UInt32, _ b: UInt32) -> Path {
            let path = Path(roundedRect: CGRect(x: x, y: y, width: 64, height: 64), cornerRadius: 18, style: .continuous)
            context.fill(path, with: .linearGradient(Gradient(colors: [Color(hex: a), Color(hex: b)]),
                                                     startPoint: CGPoint(x: x, y: y), endPoint: CGPoint(x: x + 64, y: y + 64)))
            return path
        }
        _ = tile(52, 76, 0x97EEF7, 0x2698C4)
        context.stroke(circle(84, 108, 13), with: .color(.white), lineWidth: 5)
        _ = tile(52, 148, 0xFFD592, 0xEC8430)
        var triangle = Path()
        triangle.move(to: CGPoint(x: 72, y: 190))
        triangle.addLine(to: CGPoint(x: 84, y: 168))
        triangle.addLine(to: CGPoint(x: 96, y: 190))
        triangle.closeSubpath()
        context.fill(triangle, with: .color(.white.opacity(0.95)))
        _ = tile(124, 148, 0xFFB6D4, 0xDC4C88)
        context.fill(Path(roundedRect: CGRect(x: 142, y: 166, width: 28, height: 28), cornerRadius: 8), with: .color(.white.opacity(0.95)))
        context.stroke(Path(roundedRect: CGRect(x: 125, y: 77, width: 62, height: 62), cornerRadius: 17, style: .continuous),
                       with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 2, dash: [6, 6], dashPhase: spinning ? t * 24 : 0))

        let lift = sin(t * 2 * .pi / (spinning ? 1.2 : 3.6)) * 5
        context.fill(ellipse(160, 66, 30 - lift, 6), with: .color(.black.opacity(0.18)))
        context.drawLayer { layer in
            layer.translateBy(x: 0, y: lift)
            layer.translateBy(x: 172, y: 38)
            layer.rotate(by: .degrees(12))
            layer.translateBy(x: -32, y: -32)
            let lifted = Path(roundedRect: CGRect(x: 0, y: 0, width: 64, height: 64), cornerRadius: 18, style: .continuous)
            layer.fill(lifted, with: .linearGradient(Gradient(colors: [Color(hex: 0xC4B8FF), Color(hex: 0x6A52E6)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 64, y: 64)))
            layer.stroke(Path(roundedRect: CGRect(x: 0.75, y: 0.75, width: 62.5, height: 62.5), cornerRadius: 17.25, style: .continuous),
                         with: .color(.white.opacity(0.5)), lineWidth: 1.5)
            var lines = Path()
            for (y, w) in [(24.0, 24.0), (32, 24), (40, 16)] {
                lines.move(to: CGPoint(x: 20, y: y))
                lines.addLine(to: CGPoint(x: 20 + w, y: y))
            }
            layer.stroke(lines, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
        var arrow = Path()
        arrow.move(to: CGPoint(x: 112, y: 36))
        arrow.addLine(to: CGPoint(x: 112, y: 22))
        arrow.move(to: CGPoint(x: 104, y: 30))
        arrow.addLine(to: CGPoint(x: 112, y: 22))
        arrow.addLine(to: CGPoint(x: 120, y: 30))
        context.stroke(arrow, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    // MARK: Done

    static func drawDone(_ context: inout GraphicsContext, t: Double) {
        func ease(_ x: Double) -> Double { let c = min(max(x, 0), 1); return 1 - pow(1 - c, 3) }
        func overshoot(_ x: Double) -> Double {
            let c = min(max(x, 0), 1)
            let s = 1.70158 * 1.4
            return 1 + (s + 1) * pow(c - 1, 3) + s * pow(c - 1, 2)
        }
        shadow(&context, cx: 120, cy: 222, rx: 80, ry: 11)

        context.drawLayer { layer in
            layer.translateBy(x: 120, y: 116)
            layer.rotate(by: .radians(t * 2 * .pi / 40))
            layer.translateBy(x: -120, y: -116)
            layer.stroke(circle(120, 116, 100), with: .color(Color(hex: 0x8FEAF7).opacity(0.35)),
                         style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 9]))
        }

        let ripple = ease((t - 0.5) / 1.4)
        if ripple > 0 && ripple < 1 {
            context.stroke(circle(120, 116, 86 * (1 + ripple * 0.5)), with: .color(Color(hex: 0xA6F2FB).opacity(0.6 * (1 - ripple))), lineWidth: 2)
        }

        let pop = overshoot(t / 0.7)
        context.drawLayer { layer in
            layer.opacity = min(t / 0.25, 1)
            layer.translateBy(x: 120, y: 116)
            layer.scaleBy(x: 0.55 + 0.45 * pop, y: 0.55 + 0.45 * pop)
            layer.translateBy(x: -120, y: -116)
            layer.fill(circle(120, 116, 84), with: .radialGradient(
                Gradient(stops: [.init(color: Color(hex: 0xB2F7FF), location: 0), .init(color: Color(hex: 0x2DB4D9), location: 0.5), .init(color: Color(hex: 0x0D557F), location: 1)]),
                center: CGPoint(x: 91, y: 92), startRadius: 0, endRadius: 151))
            layer.stroke(circle(120, 116, 83), with: .color(.white.opacity(0.45)), lineWidth: 2)
            var gloss = Path()
            gloss.addArc(center: CGPoint(x: 120, y: 116), radius: 62, startAngle: .degrees(205), endAngle: .degrees(250), clockwise: false)
            layer.stroke(gloss, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        }

        var check = Path()
        check.move(to: CGPoint(x: 84, y: 118))
        check.addLine(to: CGPoint(x: 108, y: 142))
        check.addLine(to: CGPoint(x: 158, y: 88))
        let drawn = ease((t - 0.35) / 0.6)
        if drawn > 0 {
            context.stroke(check.trimmedPath(from: 0, to: drawn), with: .color(.white),
                           style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))
        }

        for (x, y, r, period, delay) in [(204.0, 44.0, 8.0, 1.8, 0.6), (38, 64, 5, 2.2, 0.9), (210, 172, 5, 2, 1.2)] {
            guard t > delay else { continue }
            let twinkle = 0.25 + 0.75 * (0.5 + 0.5 * sin((t - delay) * 2 * .pi / period))
            let scale = 0.7 + 0.45 * twinkle
            var star = Path()
            let points = [(0.0, -1.0), (0.38, -0.38), (1, 0), (0.38, 0.38), (0, 1), (-0.38, 0.38), (-1, 0), (-0.38, -0.38)]
            for (index, point) in points.enumerated() {
                let p = CGPoint(x: x + point.0 * r * scale, y: y + point.1 * r * scale)
                if index == 0 { star.move(to: p) } else { star.addLine(to: p) }
            }
            star.closeSubpath()
            context.fill(star, with: .color(Color(hex: 0xBFF6FF).opacity(twinkle)))
        }

        let ring = Color(hex: 0x9FF0FF)
        risingBubble(&context, x: 60, y: 190, r: 5, t: t, period: 2.6, delay: 0.4, color: ring)
        risingBubble(&context, x: 186, y: 200, r: 7, t: t, period: 3, delay: 1.1, color: ring)
        risingBubble(&context, x: 150, y: 214, r: 3.5, t: t, period: 2.4, delay: 1.7, color: ring)
    }
}
