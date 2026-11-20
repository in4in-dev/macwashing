import AppKit
import SwiftUI

/// The «Aqua 2008» app icon: a glossy bubble in the macOS icon grid. Drawn in a 100×100 space.
struct AquaIcon: View {
    private struct Colors {
        let bg: [Color]
        let glass: [Color]
    }

    private var colors: Colors {
        Colors(bg: [Color(hex: 0x3E4756), Color(hex: 0x1A1F27), Color(hex: 0x0C0F13)],
               glass: [Color(hex: 0xA6F2FB), Color(hex: 0x27A9D3), Color(hex: 0x0B4C74)])
    }

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 100
            func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
                CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let c = colors

            // Squircle with sheen and rim.
            let squircle = Path(roundedRect: rect(8, 8, 84, 84), cornerRadius: 19 * s, style: .continuous)
            context.fill(squircle, with: .linearGradient(Gradient(colors: c.bg), startPoint: point(8, 8), endPoint: point(38, 92)))
            context.fill(squircle, with: .linearGradient(
                Gradient(stops: [.init(color: .white.opacity(0.22), location: 0), .init(color: .white.opacity(0), location: 0.5)]),
                startPoint: point(50, 8), endPoint: point(50, 92)))
            context.stroke(Path(roundedRect: rect(8.5, 8.5, 83, 83), cornerRadius: 18.5 * s, style: .continuous),
                           with: .color(.white.opacity(0.16)), lineWidth: s)

            // Bubble.
            let glass = Gradient(stops: [.init(color: c.glass[0], location: 0), .init(color: c.glass[1], location: 0.55), .init(color: c.glass[2], location: 1)])
            let bubble = Path(ellipseIn: rect(21, 24, 58, 58))
            context.fill(bubble, with: .radialGradient(glass, center: point(41.9, 41.4), startRadius: 0, endRadius: 52 * s))
            context.stroke(Path(ellipseIn: rect(21.5, 24.5, 57, 57)), with: .color(.white.opacity(0.4)), lineWidth: s)

            // Top gloss: upper half of a tall ellipse joined with the lower half of a flat one.
            var gloss = Path()
            gloss.addPath(Path(ellipseIn: rect(27, 30, 46, 30)).intersection(Path(rect(0, 0, 100, 45))))
            gloss.addPath(Path(ellipseIn: rect(27, 37, 46, 16)).intersection(Path(rect(0, 45, 100, 55))))
            context.fill(gloss, with: .linearGradient(
                Gradient(stops: [.init(color: .white.opacity(0.92), location: 0), .init(color: .white.opacity(0.08), location: 1)]),
                startPoint: point(50, 30), endPoint: point(50, 53)))

            // Bottom reflection.
            context.fill(Path(ellipseIn: rect(35, 68.5, 30, 9)), with: .color(.white.opacity(0.28)))

            // Small bubbles.
            context.fill(Path(ellipseIn: rect(71, 19, 10, 10)), with: .radialGradient(glass, center: point(74.6, 22), startRadius: 0, endRadius: 9 * s))
            context.fill(Path(ellipseIn: rect(72.4, 20.9, 5.2, 3.2)), with: .color(.white.opacity(0.85)))
            context.fill(Path(ellipseIn: rect(81.6, 32.6, 4.8, 4.8)), with: .radialGradient(glass, center: point(83.3, 34), startRadius: 0, endRadius: 4.5 * s))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The Dock icon: the washer mark.
@MainActor
enum AppIconManager {
    static func apply() {
        NSApp.applicationIconImage = render(size: 512, scale: 2)
    }

    /// The icon on the macOS grid: the body inset by a tenth, with a soft shadow.
    static func render(size: CGFloat, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: WasherIcon(margin: 0.1).frame(width: size, height: size))
        renderer.scale = scale
        return renderer.nsImage
    }

    #if DEBUG
    /// `MW_RENDER_ICON=<folder>`: writes the app icon PNGs (for the asset catalog) and quits.
    static func renderAssetsIfAsked() {
        guard let folder = ProcessInfo.processInfo.environment["MW_RENDER_ICON"] else { return }
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            guard let image = render(size: CGFloat(pixels), scale: 1),
                  let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(filePath: folder).appending(path: "icon-\(pixels).png"))
        }
        exit(0)
    }
    #endif
}
