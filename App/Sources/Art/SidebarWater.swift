import AppKit
import FluidKit
import Observation
import SwiftUI

/// Water poured into the sidebar, simulated as a particle fluid (see `FluidSim`):
/// - at rest there is a little of it at the bottom; while work is running the tank fills up almost to the top, and it
///   drains back afterwards;
/// - it flows wherever gravity points (the Mac's tilt, from the accelerometer), even upside down;
/// - dragging the window or shaking the Mac throws it about, and it splits into chunks and drops;
/// - things float on it (the logo, the DevMode badge) and always come up to the surface;
/// - clicks under water release groups of bubbles; while work runs, the bottom boils where water touches it;
///   bubbles rise against gravity, knock the floating things, and pop at the surface.
/// When everything is still the simulation falls asleep and costs nothing.
@MainActor
@Observable
final class WaterState {
    /// Surface height from the sidebar top while work is running (the tank almost full).
    static let busyLevel: CGFloat = 50

    /// True while nothing moves; the timelines pause.
    private(set) var sleeping = false

    @ObservationIgnored private(set) var sim: FluidSim?
    @ObservationIgnored private(set) var size: CGSize = .zero

    /// Where the surface settles at rest, from the sidebar top (set once by the view: two menu rows below the menu).
    @ObservationIgnored var restLevel: CGFloat? {
        didSet { if sim == nil { createIfReady() } }
    }
    private var restSurface: CGFloat? { restLevel }
    /// Water particles at rest and while busy.
    @ObservationIgnored private var restCount = 0
    @ObservationIgnored private var busyCount = 0

    // MARK: Floating things

    struct Floater {
        /// Its place in the layout (in tank coordinates); the view is offset from there.
        var rest: CGRect
        /// Starts afloat on the surface rather than at its layout place.
        var startsOnSurface: Bool
        var body: Int?
        var offset: CGSize = .zero
        var angle: Double = 0
    }

    @ObservationIgnored private var floaters: [String: Floater] = [:]
    @ObservationIgnored private var floaterOrder: [String] = []
    /// A floating box may float either face up; the view is turned so its text reads upright against gravity.
    private(set) var flipped: Set<String> = []

    /// The layout place of a floating thing; the first call adds it to the water.
    func setRest(_ id: String, _ rect: CGRect, startsOnSurface: Bool) {
        guard rect.width > 10, rect.height > 5 else { return }
        if floaters[id] == nil {
            floaters[id] = Floater(rest: rect, startsOnSurface: startsOnSurface)
            floaterOrder.append(id)
            addBody(for: id)
        } else {
            floaters[id]?.rest = rect
        }
    }

    func offset(of id: String) -> CGSize { floaters[id]?.offset ?? .zero }
    func angle(of id: String) -> Double { floaters[id]?.angle ?? 0 }

    private func addBody(for id: String) {
        guard let sim, let floater = floaters[id], floater.body == nil else { return }
        // A little narrower and flatter than the layout frame: padding is not solid.
        let half = SIMD2(Float(floater.rest.width) / 2 - 5, max(Float(floater.rest.height) / 2 - 3, 5))
        let y = floater.startsOnSurface ? Float(restSurface ?? floater.rest.midY) - 2 : Float(floater.rest.midY)
        let drawn = SIMD2(Float(floater.rest.width) / 2, Float(floater.rest.height) / 2)
        floaters[id]?.body = sim.addBody(center: SIMD2(Float(floater.rest.midX), y), halfSize: half, extent: drawn)
        readFloaters()
    }

    // MARK: Gravity and shoves

    /// Gravity in screen coordinates (y down), from the accelerometer when there is one.
    @ObservationIgnored private var gravity = SIMD2<Float>(0, 1)
    @ObservationIgnored private var windowOrigin: CGPoint?
    @ObservationIgnored private var sampledOrigin: CGPoint?
    @ObservationIgnored private var windowVelocity = SIMD2<Float>(0, 0)

    // MARK: Bubbles

    struct Bubble {
        var position: SIMD2<Float>
        var radius: Float
        var wobble: Float
        var delay: Float
        var touched: Int?
    }

    struct Pop {
        var position: SIMD2<Float>
        var radius: Float
        var age: Float
    }

    @ObservationIgnored private(set) var bubbles: [Bubble] = []
    @ObservationIgnored private(set) var pops: [Pop] = []
    @ObservationIgnored var boiling = false {
        didSet {
            if boiling, !oldValue { boilStarted = .now }
            if !boiling, oldValue { boilStopped = .now }
            if boiling != oldValue { wake() }
        }
    }
    @ObservationIgnored private var boilStarted: Date = .now
    @ObservationIgnored private var boilStopped: Date = .distantPast
    /// Bubbles keep coming for a moment after the work ends, while the water already starts to go down.
    private var bubbling: Bool { boiling || Date.now.timeIntervalSince(boilStopped) < 1.3 }
    /// 0 clear, 1 murky: the water thickens while work is running and clears again afterwards.
    @ObservationIgnored private(set) var murk: Float = 0
    @ObservationIgnored private var boilDebt: Float = 0
    @ObservationIgnored private var fillDebt: Float = 0
    @ObservationIgnored private var boilSites: [Float] = [0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 0.95]
    private static let maxBubbles = 900

    @ObservationIgnored private var lastStep: Date?
    /// Last time something disturbed the water (a drag, a tilt, a click, a bubble, boiling).
    @ObservationIgnored private var lastDisturbance: Date = .now
    @ObservationIgnored private var quietFor: Float = 0

    // MARK: Setup

    func resize(to newSize: CGSize) {
        guard newSize != size, newSize.width > 20, newSize.height > 80 else { return }
        size = newSize
        if let sim {
            sim.resize(width: Float(newSize.width), height: Float(newSize.height))
        } else {
            createIfReady()
        }
        wake()
    }

    private func createIfReady() {
        guard sim == nil, let restSurface, size.width > 20, restSurface > Self.busyLevel + 20, restSurface < size.height - 20 else { return }
        let width = Float(size.width), height = Float(size.height)
        let sim = FluidSim(width: width, height: height, fillTo: Float(restSurface))
        self.sim = sim
        restCount = sim.count
        busyCount = FluidSim.particleCount(width: width, height: height, level: Float(Self.busyLevel))
        for id in floaterOrder { addBody(for: id) }
        // Let it settle once so the first frame is calm water, not a lattice.
        for _ in 0..<90 { sim.step(seconds: 1 / 60) }
        readFloaters()
        wake()
    }

    // MARK: Input

    func windowMoved(to origin: CGPoint) {
        windowOrigin = origin
        wake()
    }

    /// An accelerometer sample in g, in the Mac's base frame (x to the right, y towards the hinge, z up).
    /// The reading is what the water feels (gravity minus the Mac's own acceleration), so shakes come with it.
    func motion(_ sample: SIMD3<Double>) {
        // The screen stands on the hinge at about 110°: its "up" in the base frame.
        let lidUp = SIMD3<Double>(0, 0.342, 0.94)
        let down = -(sample.y * lidUp.y + sample.z * lidUp.z)
        let target = SIMD2(Float(sample.x * Self.tiltSign), Float(down))
        let smoothed = gravity + (target - gravity) * 0.35
        let change = abs(smoothed.x - gravity.x) + abs(smoothed.y - gravity.y)
        gravity = smoothed
        if change > 0.02 { wake() }
    }

    /// Which way the sensor's x axis points relative to the screen.
    static let tiltSign = 1.0

    /// A click in the tank: bubbles if it is under water, a push if it is on something floating.
    func burst(at point: CGPoint) {
        guard let sim else { return }
        let p = SIMD2(Float(point.x), Float(point.y))
        if let body = bodyAt(p, margin: 4) {
            sim.nudgeBody(body, at: p, velocity: gravityDirection * 70)
        }
        if sim.wetness(at: p).0 > 0.3 {
            for index in 0..<Int.random(in: 6...10) {
                addBubble(at: p + SIMD2(.random(in: -9...9), .random(in: -9...9)),
                          radius: .random(in: 1.3...3.8), delay: Float(index) * .random(in: 0.02...0.06))
            }
        }
        wake()
    }

    private var gravityDirection: SIMD2<Float> {
        let length = (gravity.x * gravity.x + gravity.y * gravity.y).squareRoot()
        return length > 0.05 ? gravity / length : SIMD2(0, 1)
    }

    /// Holding the button down under water: a stream of bubbles where the pointer is, growing the longer it is held
    /// (`held` seconds; full strength after `streamRamp`).
    func stream(at point: CGPoint, held: TimeInterval) {
        guard let sim else { return }
        let p = SIMD2(Float(point.x), Float(point.y))
        guard sim.wetness(at: p).0 > 0.3 else { return }
        let strength = Float(min(held / Self.streamRamp, 1))
        let count = 2 + Int((strength * 6).rounded())
        let spread = 6 + strength * 8
        for index in 0..<count {
            addBubble(at: p + SIMD2(.random(in: -spread...spread), .random(in: -spread...spread)),
                      radius: .random(in: (1.1 + strength)...(3.2 + strength * 2.8)),
                      delay: Float(index) * .random(in: 0.01...0.04))
        }
        // A strong stream also stirs the water around the pointer.
        if strength > 0.4 { sim.kick(at: p, radius: 10 + 14 * strength, velocity: -gravityDirection * 40 * strength) }
        wake()
    }
    private static let streamRamp: TimeInterval = 3

    private func addBubble(at position: SIMD2<Float>, radius: Float, delay: Float = 0) {
        guard bubbles.count < Self.maxBubbles else { return }
        bubbles.append(Bubble(position: position, radius: radius, wobble: .random(in: 0...(2 * .pi)), delay: delay))
    }

    private func wake() {
        quietFor = 0
        lastDisturbance = .now
        if sleeping {
            sleeping = false
            lastStep = nil
        }
    }

    // MARK: Simulation

    /// Advances to `date`; repeated calls for the same frame are no-ops.
    func step(to date: Date) {
        guard !sleeping, let sim else { return }
        guard let last = lastStep else {
            lastStep = date
            return
        }
        let elapsed = Float(min(date.timeIntervalSince(last), 1.0 / 20))
        guard elapsed > 0 else { return }
        lastStep = date

        // Fill up while work runs, drain afterwards: steady, easing off near the end (about 5 s either way). Faster
        // than ~300 particles a second the new water churns instead of settling.
        let target = boiling ? busyCount : restCount
        if sim.waterAmount != target {
            let span = Float(max(busyCount - restCount, 1))
            let remaining = Float(abs(target - sim.waterAmount))
            fillDebt += elapsed * min(max(remaining * 0.9, span * 0.05), 380)
            let amount = min(Int(fillDebt), abs(target - sim.waterAmount))
            fillDebt -= Float(amount)
            if target > sim.waterAmount { sim.addWater(amount) } else { sim.removeWater(amount) }
            lastDisturbance = .now
        } else {
            fillDebt = 0
        }
        if !bubbles.isEmpty || bubbling { lastDisturbance = .now }
        // Left alone, the water loses its energy over a couple of seconds (friction ramps up), then sleeps once it
        // has really stopped — it never freezes mid-wave.
        let idle = Float(Date.now.timeIntervalSince(lastDisturbance))
        sim.calming = min(max((idle - 2.5) / 2, 0), 1)
        sim.gravity = gravity
        sim.push = -windowAcceleration(elapsed)
        let (typical, fastest) = sim.step(seconds: elapsed)
        murk += ((boiling ? 1 : 0) - murk) * min(elapsed * 2, 1)
        stepBubbles(elapsed, sim: sim)
        readFloaters()

        let still = sim.calming >= 1 && typical < 6 && fastest < 90 && pops.isEmpty && murk < 0.01
        quietFor = still ? quietFor + elapsed : 0
        if quietFor > 0.5 { sleeping = true }
    }

    /// The window's acceleration in tank coordinates (x right, y down), from its moves since the last frame.
    private func windowAcceleration(_ elapsed: Float) -> SIMD2<Float> {
        guard let origin = windowOrigin else { return .zero }
        defer { sampledOrigin = origin }
        guard let previous = sampledOrigin else { return .zero }
        let dx = Float(origin.x - previous.x), dy = Float(origin.y - previous.y)
        guard abs(dx) + abs(dy) < 600 else {
            windowVelocity = .zero
            return .zero
        }
        let velocity = SIMD2(dx / elapsed, -dy / elapsed)        // AppKit y goes up
        var acceleration = (velocity - windowVelocity) / elapsed
        windowVelocity = velocity
        let limit: Float = 12000
        acceleration.x = min(max(acceleration.x, -limit), limit)
        acceleration.y = min(max(acceleration.y, -limit), limit)
        return acceleration * 0.6
    }

    private func readFloaters() {
        guard let sim else { return }
        let bodies = sim.bodies
        for id in floaterOrder {
            guard let floater = floaters[id], let index = floater.body, bodies.indices.contains(index) else { continue }
            let body = bodies[index]
            floaters[id]?.offset = CGSize(width: CGFloat(body.center.x) - floater.rest.midX,
                                          height: CGFloat(body.center.y) - floater.rest.midY)
            floaters[id]?.angle = Double(body.angle)
            // Its "up" (the −y axis, turned) against gravity: flip the drawing when it faces down.
            let up = SIMD2(sin(body.angle), -cos(body.angle))
            let facing = up.x * gravityDirection.x + up.y * gravityDirection.y
            if !flipped.contains(id), facing > 0.25 { flipped.insert(id) }
            if flipped.contains(id), facing < -0.25 { flipped.remove(id) }
        }
    }

    private func stepBubbles(_ dt: Float, sim: FluidSim) {
        let up = -gravityDirection
        let side = SIMD2(-up.y, up.x)
        if bubbling {
            // The longer the work runs, the harder it boils: from a trickle to a full boil over about 20 s.
            // A heater along the tank's bottom edge: bubbles only where water touches it.
            let t = min(Float(Date.now.timeIntervalSince(boilStarted)) / 20, 1)
            // Three times as many while the tank is still filling.
            let filling = boiling && sim.waterAmount < busyCount - 10
            boilDebt += dt * (25 + 175 * t * t * (3 - 2 * t)) * (filling ? 3 : 1)
            var tries = 0
            while boilDebt >= 1, tries < 1200 {
                tries += 1
                let fromSite = Float.random(in: 0...1) < 0.55
                let unit = fromSite ? boilSites.randomElement()! + .random(in: -0.03...0.03) : .random(in: 0.03...0.97)
                let spot = SIMD2(unit * Float(size.width), Float(size.height) - 6)
                guard sim.wetness(at: spot).0 > 0.5 else { continue }
                boilDebt -= 1
                let big = Float.random(in: 0...1) < 0.15
                addBubble(at: spot, radius: big ? .random(in: 3.5...5.5) : .random(in: 1...3.2))
            }
            boilDebt = min(boilDebt, 5)
            for index in boilSites.indices {
                boilSites[index] = min(max(boilSites[index] + .random(in: -0.12...0.12) * dt, 0.05), 0.95)
            }
        } else {
            boilDebt = 0
        }

        var index = 0
        while index < bubbles.count {
            var bubble = bubbles[index]
            if bubble.delay > 0 {
                bubble.delay -= dt
                bubbles[index] = bubble
                index += 1
                continue
            }
            // Rise against gravity (turning when the Mac turns), wobble sideways, drift with the water.
            let (wet, flow) = sim.wetness(at: bubble.position)
            bubble.wobble += dt * (5 + 6 / bubble.radius)
            let rise = up * (34 + bubble.radius * 15)
            let sway = side * sin(bubble.wobble) * (9 / bubble.radius + 3)
            bubble.position += (rise + sway + flow * 0.6) * dt
            bubble.position.x = min(max(bubble.position.x, bubble.radius), Float(size.width) - bubble.radius)
            bubble.position.y = min(max(bubble.position.y, bubble.radius), Float(size.height) - bubble.radius)

            slideUnderBodies(&bubble, up: up, dt: dt, sim: sim)

            // Out of the water: it pops, leaving a ring and a little ripple.
            let heldUnder = bubble.touched.map { bodyContains($0, bubble.position, margin: bubble.radius + 3) } ?? false
            if wet < 0.25, !heldUnder {
                pops.append(Pop(position: bubble.position, radius: bubble.radius, age: 0))
                sim.kick(at: bubble.position, radius: 14, velocity: up * bubble.radius * 12)
                bubbles.remove(at: index)
                continue
            }
            bubbles[index] = bubble
            index += 1
        }
        for index in pops.indices { pops[index].age += dt }
        pops.removeAll { $0.age > 0.35 }
    }

    /// A bubble reaching something floating knocks it (weakly) where it hit, then slides along its side to the higher end.
    private func slideUnderBodies(_ bubble: inout Bubble, up: SIMD2<Float>, dt: Float, sim: FluidSim) {
        let bodies = sim.bodies
        for (index, body) in bodies.enumerated() {
            let c = cos(body.angle), s = sin(body.angle)
            let d = bubble.position - body.center
            var local = SIMD2(d.x * c + d.y * s, -d.x * s + d.y * c)
            let half = body.halfSize + bubble.radius
            guard abs(local.x) < half.x, abs(local.y) < half.y else { continue }
            let localUp = SIMD2(up.x * c + up.y * s, -up.x * s + up.y * c)
            if bubble.touched != index {
                bubble.touched = index
                sim.nudgeBody(index, at: bubble.position, velocity: up * (bubble.radius * bubble.radius * 0.5 + 1.5))
            }
            // Held on the side facing the water below, drifting along the long side towards "up".
            local.y = localUp.y < 0 ? half.y : -half.y
            let along: Float = localUp.x > 0.02 ? 1 : (localUp.x < -0.02 ? -1 : (local.x >= 0 ? 1 : -1))
            local.x += along * (22 + abs(localUp.x) * 160) * dt
            bubble.position = body.center + SIMD2(local.x * c - local.y * s, local.x * s + local.y * c)
            return
        }
    }

    private func bodyAt(_ point: SIMD2<Float>, margin: Float) -> Int? {
        guard let sim else { return nil }
        return sim.bodies.indices.first { bodyContains($0, point, margin: margin) }
    }

    private func bodyContains(_ index: Int, _ point: SIMD2<Float>, margin: Float) -> Bool {
        guard let sim, sim.bodies.indices.contains(index) else { return false }
        let body = sim.bodies[index]
        let c = cos(body.angle), s = sin(body.angle)
        let d = point - body.center
        let local = SIMD2(d.x * c + d.y * s, -d.x * s + d.y * c)
        return abs(local.x) < body.halfSize.x + margin && abs(local.y) < body.halfSize.y + margin
    }
}

/// The water body and its bubbles, drawn behind the sidebar content.
/// Particles are drawn as soft discs, blurred together and cut at half opacity ("metaballs"), so the water has
/// smooth edges and splits and merges like a liquid. A second cut, shifted along gravity, leaves a bright rim on
/// the surfaces facing up.
struct SidebarWater: View {
    let state: WaterState
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsLive) private var animationsLive

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || !animationsLive || state.sleeping)) { timeline in
            Canvas { context, size in
                state.resize(to: size)
                if !reduceMotion { state.step(to: timeline.date) }
                guard let sim = state.sim else { return }
                let murk = Double(state.murk)
                let tint = palette.accent
                let radius = CGFloat(sim.parameters.spacing) * 0.95
                var blobs = Path()
                for i in 0..<sim.count {
                    // New water grows in and removed water shrinks away.
                    let r = radius * CGFloat(sim.weight[i]).squareRoot()
                    guard r > 0.5 else { continue }
                    blobs.addEllipse(in: CGRect(x: CGFloat(sim.x[i]) - r, y: CGFloat(sim.y[i]) - r, width: r * 2, height: r * 2))
                }
                // Body of water: brighter near the surface, fading towards the bottom (along gravity).
                let down = sim.gravity
                let downLength = max((down.x * down.x + down.y * down.y).squareRoot(), 0.05)
                let direction = CGPoint(x: CGFloat(down.x / downLength), y: CGFloat(down.y / downLength))
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let reach = (abs(direction.x) * size.width + abs(direction.y) * size.height) / 2
                let top = CGPoint(x: center.x - direction.x * reach, y: center.y - direction.y * reach)
                let bottom = CGPoint(x: center.x + direction.x * reach, y: center.y + direction.y * reach)
                context.drawLayer { layer in
                    layer.drawLayer { shape in
                        shape.addFilter(.alphaThreshold(min: 0.5, color: .black))
                        shape.addFilter(.blur(radius: radius * 0.7))
                        shape.fill(blobs, with: .color(.black))
                    }
                    layer.blendMode = .sourceIn
                    layer.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.03 + 0.21 * murk), tint.opacity(0.006 + 0.074 * murk)]),
                        startPoint: top, endPoint: bottom))
                }
                // Bright rim where the surface faces up: the same shape minus itself shifted along gravity.
                context.drawLayer { layer in
                    layer.opacity = 0.24 + 0.36 * murk
                    layer.drawLayer { rim in
                        rim.addFilter(.alphaThreshold(min: 0.5, color: tint))
                        rim.addFilter(.blur(radius: radius * 0.7))
                        rim.fill(blobs, with: .color(.black))
                    }
                    layer.blendMode = .destinationOut
                    layer.drawLayer { cut in
                        cut.addFilter(.alphaThreshold(min: 0.5, color: .black))
                        cut.addFilter(.blur(radius: radius * 0.7))
                        let shift = sim.gravity
                        let length = max((shift.x * shift.x + shift.y * shift.y).squareRoot(), 0.05)
                        cut.translateBy(x: CGFloat(shift.x / length) * 1.6, y: CGFloat(shift.y / length) * 1.6)
                        cut.fill(blobs, with: .color(.black))
                    }
                }

                for bubble in state.bubbles where bubble.delay <= 0 {
                    let r = CGFloat(bubble.radius)
                    let rect = CGRect(x: CGFloat(bubble.position.x) - r, y: CGFloat(bubble.position.y) - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.08)))
                    context.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(0.45)), lineWidth: 0.8)
                    if r > 2 {
                        let glint = CGRect(x: rect.midX - r * 0.45, y: rect.midY - r * 0.55, width: r * 0.45, height: r * 0.45)
                        context.fill(Path(ellipseIn: glint), with: .color(.white.opacity(0.45)))
                    }
                }
                for pop in state.pops {
                    let progress = CGFloat(pop.age / 0.35)
                    let r = CGFloat(pop.radius) * (1 + progress * 1.6)
                    context.stroke(
                        Path(ellipseIn: CGRect(x: CGFloat(pop.position.x) - r, y: CGFloat(pop.position.y) - r, width: r * 2, height: r * 2)),
                        with: .color(tint.opacity(0.45 * (1 - progress))), lineWidth: 0.8)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Rides the water: offset and rotation come from the simulated floating body with this id.
struct FloatOnWater: ViewModifier {
    let state: WaterState
    let id: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsLive) private var animationsLive

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || !animationsLive || state.sleeping)) { timeline in
            let _ = reduceMotion ? () : state.step(to: timeline.date)
            content
                .rotationEffect(.radians(state.flipped.contains(id) ? .pi : 0))
                .animation(Motion.bouncy, value: state.flipped.contains(id))
                .rotationEffect(.radians(state.angle(of: id)))
                .offset(state.offset(of: id))
        }
    }
}

/// Reports window moves and clicks inside the tank to the water. Clicks pass through to the buttons underneath.
struct WaterInputReader: NSViewRepresentable {
    let state: WaterState

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.state = state
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var state: WaterState?
        private var moveObserver: NSObjectProtocol?
        private var clickMonitor: Any?
        /// While the button is held down in the tank, bubbles keep coming where the pointer is.
        private var holdTimer: Timer?
        private var holdPoint: CGPoint = .zero
        private var holdStart = Date()

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopListening()
            guard let window else { return }
            state?.windowMoved(to: window.frame.origin)
            moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] note in
                guard let moved = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.state?.windowMoved(to: moved.frame.origin) }
            }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    switch event.type {
                    case .leftMouseDown:
                        guard self.bounds.contains(point) else { return }
                        self.state?.burst(at: point)
                        self.startHold(at: point)
                    case .leftMouseDragged:
                        self.holdPoint = point
                    default:
                        self.stopHold()
                    }
                }
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            // Stop listening before leaving a window (also covers teardown).
            if newWindow == nil { stopListening() }
        }

        private func startHold(at point: CGPoint) {
            stopHold()
            holdPoint = point
            holdStart = .now
            // Common modes: a held button runs the event-tracking run loop mode, where a default-mode timer waits.
            let timer = Timer(timeInterval: 0.11, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.bounds.contains(self.holdPoint) else { return }
                    self.state?.stream(at: self.holdPoint, held: Date.now.timeIntervalSince(self.holdStart))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }

        private func stopHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }

        private func stopListening() {
            stopHold()
            if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            moveObserver = nil
            clickMonitor = nil
        }
    }
}
