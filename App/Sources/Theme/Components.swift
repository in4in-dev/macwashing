import SwiftUI

enum CheckState: Equatable {
    case on, mixed, off

    init(selected: Int, total: Int) {
        self = selected == 0 ? .off : (selected == total ? .on : .mixed)
    }
}

/// Round checkbox with a springy mark.
struct CheckMark: View {
    @Environment(\.palette) private var palette
    let state: CheckState

    var body: some View {
        ZStack {
            Circle()
                .fill(state == .off ? Color.clear : palette.accent)
            Circle()
                .strokeBorder(state == .off ? palette.checkRing : palette.accent, lineWidth: 1.5)
            if state != .off {
                Image(systemName: state == .on ? "checkmark" : "minus")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(palette.onAccent)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: 20, height: 20)
        .shadow(color: state == .off ? .clear : .black.opacity(0.18), radius: 5, y: 2)
        .animation(Motion.bouncy, value: state)
    }
}

/// A 32×32 hit area around a checkbox.
struct CheckButton: View {
    let state: CheckState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CheckMark(state: state)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.row)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? Text("выбрано") : state == .mixed ? Text("частично") : Text("не выбрано"))
    }
}

/// Filled capsule button with a breathing glow.
struct PrimaryButton: View {
    @Environment(\.palette) private var palette
    @Environment(\.animationsLive) private var animationsLive
    let title: LocalizedStringKey
    var systemImage: String?
    var enabled = true
    var height: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .bold))
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 28)
            .frame(height: height)
            .foregroundStyle(enabled ? palette.onAccent : palette.faint)
            .background(HoverFill(color: enabled ? palette.accent : .white.opacity(0.1), shape: Capsule()))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle.bubbly)
        .disabled(!enabled)
        // The breathing glow sits outside the button's label: switching the label to Liquid Glass on hover
        // rebuilds the label, and a glow inside it would restart from zero.
        .background {
            let glow = Capsule().fill(palette.accent).blur(radius: 18).offset(y: 6)
            Group {
                if animationsLive {
                    glow.phaseAnimator([false, true]) { glow, breathing in
                        glow
                            .opacity(enabled ? (breathing ? 0.55 : 0.28) : 0)
                            .scaleEffect(breathing ? 1.04 : 0.94)
                    } animation: { _ in .easeInOut(duration: 1.6) }
                } else {
                    glow.opacity(enabled ? 0.4 : 0)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Secondary outlined capsule.
struct SecondaryButton: View {
    @Environment(\.palette) private var palette
    let title: LocalizedStringKey
    var height: CGFloat = 36
    /// Next to a `PrimaryButton`: its type and padding, so the pair reads as one size (give it the same height too).
    var primarySized = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: primarySized ? 15 : 13, weight: primarySized ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize()                   // never squeezed down to a letter in a tight row
                .padding(.horizontal, primarySized ? 28 : 18)
                .frame(height: height)
                .foregroundStyle(palette.text)
                .background(Capsule().fill(palette.field))
                .overlay(Capsule().strokeBorder(palette.cardStroke))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle.capsule)
    }
}

/// Fill of a prominent button: translucent over Liquid Glass at rest, solid under the pointer.
struct HoverFill<S: Shape>: View {
    let color: Color
    let shape: S
    @Environment(\.glassHover) private var hovering

    static var restingOpacity: Double { 0.8 }

    var body: some View {
        shape.fill(color.opacity(hovering ? 1 : Self.restingOpacity))
    }
}

/// Whether the enclosing pressable button is hovered. Buttons read it to thin their fill so the glass shows.
private struct GlassHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var glassHover: Bool {
        get { self[GlassHoverKey.self] }
        set { self[GlassHoverKey.self] = newValue }
    }
}

/// Capsule, round and dialog buttons on Liquid Glass. At rest the fill is translucent; under the pointer it turns
/// solid and native glass reacts to the pointer. Prominent buttons also let bubbles rise while hovered; with
/// `idleBubbles` a few rise at rest too, and many more under the pointer.
struct PressableStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(Capsule())
    var bubbles = false
    var idleBubbles = false

    static let capsule = PressableStyle()
    static let bubbly = PressableStyle(bubbles: true)
    static func rounded(_ radius: CGFloat) -> PressableStyle {
        PressableStyle(shape: AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }

    func makeBody(configuration: Configuration) -> some View {
        PressableLabel(configuration: configuration, shape: shape, bubbles: bubbles || idleBubbles, idleBubbles: idleBubbles)
    }

    private struct PressableLabel: View {
        let configuration: Configuration
        let shape: AnyShape
        let bubbles: Bool
        let idleBubbles: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let lit = hovering && isEnabled
            configuration.label
                .environment(\.glassHover, lit)
                // Glass stays on in both states, so hovering never rebuilds the label; only the fill density changes.
                .glassSurface(shape, interactive: true)
                .overlay(alignment: .top) {
                    if bubbles && !reduceMotion {
                        BubbleStream(active: lit, idle: idleBubbles && isEnabled)
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(Motion.bouncy, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.3), value: lit)
                .onHover { hovering = $0 }
                .linkCursor(isEnabled)
        }
    }
}

/// Small soap bubbles rising from the top edge of a button while it is hovered. With `idle`, a few small ones rise
/// at rest too; hovering then thickens the stream (capped, so it stays cheap). Stops while the app is in the background.
struct BubbleStream: View {
    let active: Bool
    var idle = false
    @Environment(\.animationsLive) private var animationsLive

    private struct Bubble: Identifiable {
        let id = UUID()
        let x: CGFloat        // 0…1 across the button
        let born: Date
        let radius: CGFloat
        let wobble: Double
        let life: Double
        let rise: CGFloat
    }

    @State private var bubbles: [Bubble] = []
    @State private var emitter: Task<Void, Never>?
    /// The tallest rise: the canvas above the button.
    private static let rise: CGFloat = 60
    private static let cap = 40

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 60, paused: bubbles.isEmpty || !animationsLive)) { timeline in
                Canvas { context, size in
                    let now = timeline.date
                    for bubble in bubbles {
                        let age = now.timeIntervalSince(bubble.born)
                        let progress = min(max(age / bubble.life, 0), 1)
                        guard progress < 1 else { continue }
                        let eased = 1 - pow(1 - progress, 2)
                        let x = bubble.x * size.width + CGFloat(sin(age * 5 + bubble.wobble)) * 3
                        let y = Self.rise - eased * bubble.rise
                        let r = bubble.radius * (0.6 + 0.4 * eased)
                        let alpha = min(age / 0.12, 1) * (1 - progress)
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.08 * alpha)))
                        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.55 * alpha)), lineWidth: 1)
                        let glint = CGRect(x: x - r * 0.45, y: y - r * 0.55, width: r * 0.45, height: r * 0.32)
                        context.fill(Path(ellipseIn: glint), with: .color(.white.opacity(0.8 * alpha)))
                    }
                }
            }
            .frame(width: proxy.size.width, height: Self.rise)
            .offset(y: -Self.rise + 4)
        }
        .onChange(of: [active, idle, animationsLive], initial: true) { _, _ in
            emitter?.cancel()
            let lively = active
            guard (lively || idle) && animationsLive else {
                // Let the last bubbles finish, then empty the list so the timeline pauses.
                emitter = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.7))
                    if !Task.isCancelled { bubbles.removeAll() }
                }
                return
            }
            emitter = Task { @MainActor in
                while !Task.isCancelled {
                    let now = Date()
                    bubbles.removeAll { now.timeIntervalSince($0.born) > $0.life }
                    if bubbles.count < Self.cap {
                        bubbles.append(lively
                            ? Bubble(x: .random(in: idle ? 0.06...0.94 : 0.12...0.88), born: now,
                                     radius: .random(in: idle ? 1.4...3.4 : 1.8...3.6), wobble: .random(in: 0...(2 * .pi)),
                                     life: .random(in: 0.9...1.4), rise: idle ? .random(in: 40...Self.rise) : 46)
                            : Bubble(x: .random(in: 0.15...0.85), born: now, radius: .random(in: 1.1...2.2),
                                     wobble: .random(in: 0...(2 * .pi)), life: .random(in: 1.1...1.6), rise: .random(in: 24...38)))
                    }
                    let pause = lively ? (idle ? 55...95 : 140...240) : 420...700
                    try? await Task.sleep(for: .milliseconds(Int.random(in: pause)))
                }
            }
        }
        .onDisappear { emitter?.cancel() }
    }
}

/// Text and icon buttons: pointer cursor, dims slightly on hover and more on press.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.55 : (hovering && isEnabled ? 0.72 : 1))
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .linkCursor(isEnabled)
        }
    }
}

/// Whole-row buttons: pointer cursor only; the row draws its own hover background.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .linkCursor()
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}

/// Row background that lights up on hover.
struct HoverRow: ViewModifier {
    @State private var hovering = false
    var selected = false
    var cornerRadius: CGFloat = 12
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? palette.selection : (hovering ? Color.white.opacity(0.04) : .clear))
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(Motion.spring, value: selected)
    }
}

extension View {
    func hoverRow(selected: Bool = false, cornerRadius: CGFloat = 12) -> some View {
        modifier(HoverRow(selected: selected, cornerRadius: cornerRadius))
    }

    /// Fades and lifts in with a delay, once, when first shown.
    func appearIn(delay: Double = 0, offset: CGFloat = 8) -> some View {
        modifier(AppearIn(delay: delay, offset: offset))
    }

    /// Pane surface: a faint fill and hairline over the section's background.
    func pane(_ palette: Palette, radius: CGFloat = 20) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(palette.pane))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.paneStroke))
    }

    func card(_ palette: Palette, radius: CGFloat = 16) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(palette.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.cardStroke))
    }
}

struct AppearIn: ViewModifier {
    let delay: Double
    let offset: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staggerEpoch) private var epoch

    /// The staggered cascade plays only for rows visible when a list opens. Rows reached later by
    /// scrolling appear right away, so a fast scroll never waits for rows that are already off screen.
    static let cascadeWindow: TimeInterval = 0.45

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : offset)
            .onAppear {
                let late = epoch.map { Date().timeIntervalSince($0) > Self.cascadeWindow } ?? false
                let animation = late ? Animation.easeOut(duration: 0.2) : Motion.spring.delay(reduceMotion ? 0 : delay)
                withAnimation(animation) { shown = true }
            }
    }
}

private struct StaggerEpochKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// When the enclosing list first appeared.
    var staggerEpoch: Date? {
        get { self[StaggerEpochKey.self] }
        set { self[StaggerEpochKey.self] = newValue }
    }
}

/// Marks a list: rows inside it cascade in only right after it appears.
struct StaggerList: ViewModifier {
    let key: AnyHashable
    @State private var epoch = Date()
    func body(content: Content) -> some View {
        content
            .environment(\.staggerEpoch, epoch)
            .onChange(of: key) { epoch = Date() }
    }
}

extension View {
    /// `key` restarts the cascade when the list shows different content (another category or filter).
    func staggerList(key: AnyHashable = 0) -> some View { modifier(StaggerList(key: key)) }
}

/// Screen transition: fade, lift and un-blur.
struct BlurLift: ViewModifier {
    let active: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .offset(y: active ? 12 : 0)
            .blur(radius: active ? 6 : 0)
    }
}

extension AnyTransition {
    static var screen: AnyTransition {
        .modifier(active: BlurLift(active: true), identity: BlurLift(active: false))
    }
}

/// Small tag like «Осторожно».
struct Pill: View {
    let text: LocalizedStringKey
    var color: Color
    var background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background))
    }
}

/// Segmented control drawn in the app's style.
struct SegmentedPicker<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    let options: [(Value, LocalizedStringKey)]
    @Binding var selection: Value
    var onChange: () -> Void = {}
    /// Segments get `"<identifier>.<index>"` for UI tests.
    var identifier: String?
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isOn = option.0 == selection
                Button {
                    guard !isOn else { return }
                    withAnimation(Motion.spring) { selection = option.0 }
                    onChange()
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isOn ? palette.text : palette.muted)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(.white.opacity(0.14))
                                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier(identifier.map { "\($0).\(index)" } ?? "")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.field))
    }
}

/// Switch in the app's style.
struct ToggleSwitch: View {
    @Environment(\.palette) private var palette
    @Binding var isOn: Bool
    let label: Text
    var onChange: () -> Void = {}

    init(isOn: Binding<Bool>, label: LocalizedStringKey, onChange: @escaping () -> Void = {}) {
        _isOn = isOn
        self.label = Text(label)
        self.onChange = onChange
    }

    /// A name from the system (a login item, a launch job): read out as is, never looked up or parsed as a format.
    init(isOn: Binding<Bool>, verbatim: String, onChange: @escaping () -> Void = {}) {
        _isOn = isOn
        self.label = Text(verbatim: verbatim)
        self.onChange = onChange
    }

    var body: some View {
        Button {
            withAnimation(Motion.bouncy) { isOn.toggle() }
            onChange()
        } label: {
            Capsule()
                .fill(isOn ? palette.accent : Color.white.opacity(0.2))
                .frame(width: 36, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                }
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.row)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? Text("включено") : Text("выключено"))
        .accessibilityAddTraits(.isToggle)
    }
}
