import AppKit
import SwiftUI

// The app runs on macOS 14 and newer; the look is designed for macOS 26. Everything here picks the native API where
// the system has it and a matching stand-in where it does not, so the views never check versions themselves.

/// Whether surfaces use native Liquid Glass (macOS 26) or the frosted stand-in.
enum LiquidGlass {
    static let isAvailable: Bool = {
        #if DEBUG
        // `MW_NO_GLASS=1`: the macOS 14/15 look on macOS 26, to check the stand-in without an old system.
        if ProcessInfo.processInfo.environment["MW_NO_GLASS"] == "1" { return false }
        #endif
        if #available(macOS 26, *) { return true }
        return false
    }()
}

extension View {
    /// A glass surface of `shape` behind the view: Liquid Glass on macOS 26, frosted material with a lit rim before.
    /// `interactive` lets native glass react to the pointer (buttons).
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *), LiquidGlass.isAvailable {
            glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            background(FrostedGlass(shape: shape))
        }
    }

    /// The menu bar popup's background. On macOS 26 the system's own window is Liquid Glass and nothing is added; before
    /// it the dark menu material is shaded down toward the graphite of the app, like `FrostedGlass`.
    @ViewBuilder
    func menuBarSurface() -> some View {
        if LiquidGlass.isAvailable {
            self
        } else {
            background(Color.black.opacity(0.35).ignoresSafeArea())
        }
    }

    /// Pointing-hand cursor while hovered and `enabled`.
    func linkCursor(_ enabled: Bool = true) -> some View {
        modifier(LinkCursor(enabled: enabled))
    }
}

/// The pre-26 glass: blurred backdrop, a faint top sheen and a hairline rim brighter at the top, the way Liquid
/// Glass catches light on the dark theme. The dark material alone is far lighter than Liquid Glass over the graphite
/// background (≈ 50 against ≈ 25 of 255), so it is shaded down to match.
private struct FrostedGlass<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(.black.opacity(0.45)))
            .overlay(shape.fill(LinearGradient(
                colors: [.white.opacity(0.05), .white.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )))
            .overlay(shape.stroke(LinearGradient(
                colors: [.white.opacity(0.22), .white.opacity(0.05)],
                startPoint: .top, endPoint: .bottom
            ), lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
    }
}

/// `pointerStyle(.link)` needs macOS 15; before it the cursor is pushed and popped by hand.
private struct LinkCursor: ViewModifier {
    let enabled: Bool
    @State private var hovering = false
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(enabled ? .link : nil)
        } else {
            content
                .onHover { inside in
                    hovering = inside
                    update()
                }
                .onChange(of: enabled) { update() }
                .onDisappear {
                    hovering = false
                    update()
                }
        }
    }

    private func update() {
        let wanted = hovering && enabled
        if wanted && !pushed {
            NSCursor.pointingHand.push()
            pushed = true
        } else if !wanted && pushed {
            NSCursor.pop()
            pushed = false
        }
    }
}
