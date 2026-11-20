import Foundation

/// A 2D particle fluid in a box: Position Based Fluids (Macklin & Müller 2013) with floating rigid bodies
/// (as in Macklin et al. 2014, "Unified Particle Physics"): each body is made of particles that take part in the same
/// density constraints, so it pushes water and is pushed by it, and is kept rigid by shape matching.
/// Position-based projection makes a light body behave like water (it would neither sink nor rise), so Archimedes'
/// force is added per body particle, by how much of it is under water — stronger deep down, so bodies shoot up.
///
/// Particles: `[0, count)` water, then the bodies' particles, then fixed wall particles that press back like water.
/// Water can be added and removed while running (the level rises and falls smoothly).
/// Speeds are stored in points per substep; the API uses points and seconds. Storage is raw memory for speed.
public final class FluidSim {
    public struct Parameters: Sendable {
        /// Distance between particles when the tank is filled.
        public var spacing: Float = 10
        /// Water is laid out slightly tighter than rest so that, once gravity settles it, the level ends up where asked.
        public var packing: Float = 0.96
        /// Interaction radius, in spacings.
        public var radiusFactor: Float = 2.0
        /// Constraint passes per substep: more keeps deep water from being squeezed.
        public var iterations = 4
        /// Constraint softening (PBF's ε), relative to the kernel's scale.
        public var relaxation: Float = 0.01
        /// Surface tension-like repulsion that stops particles clumping (PBF's s_corr strength).
        public var tensileStrength: Float = 0.01
        /// XSPH viscosity: how much a particle takes on its neighbours' velocity per substep.
        public var viscosity: Float = 0.05
        /// Velocity kept per second (1 = none lost); calms the leftover trembling of deep water.
        public var damping: Float = 0.7
        /// Gravity strength in pt/s² (the direction comes from `gravity`).
        public var gravityStrength: Float = 1400
        /// Lift (in g) on a body deep under water; near the surface it follows the body's density.
        public var deepLift: Float = 9
        /// Fastest a body may rise or sink (pt/s): quick, but never a catapult that flings water about.
        public var bodySpeedLimit: Float = 260
        public var substepsPerSecond: Float = 90
        public init() {}
    }

    /// Pose and motion of a floating body (derived from its particles).
    public struct Body: Sendable {
        public var center: SIMD2<Float>
        public var angle: Float                         // radians, clockwise on screen (y goes down)
        public var velocity: SIMD2<Float>               // pt/s
        public var halfSize: SIMD2<Float>
    }

    private struct BodyState {
        var offsets: [SIMD2<Float>]
        /// Index of its first particle.
        var start: Int
        /// Offsets are laid out row by row; a column runs across the body's thickness.
        var columns: Int
        /// Lift per unit of gravity when fully under water near the surface: 1/density − 1.
        var lift: Float
        /// Half-size of what is drawn for it: that, turned with the body, stays inside the tank.
        var extent: SIMD2<Float>
        var pose: Body
    }

    public let parameters: Parameters
    public private(set) var width: Float
    public private(set) var height: Float
    /// Water particles (the first `count` entries of the position arrays).
    public private(set) var count = 0
    public private(set) var x: UnsafeMutablePointer<Float>
    public private(set) var y: UnsafeMutablePointer<Float>
    public private(set) var vx: UnsafeMutablePointer<Float>
    public private(set) var vy: UnsafeMutablePointer<Float>
    private var px: UnsafeMutablePointer<Float>
    private var py: UnsafeMutablePointer<Float>
    /// Inverse mass: 1 for water and bodies, 0 for walls.
    private var inverseMass: UnsafeMutablePointer<Float>
    /// 0…1: how much a particle counts (new water grows in, removed water fades out). Read it to draw them.
    public private(set) var weight: UnsafeMutablePointer<Float>
    /// +1 growing, −1 fading, 0 steady.
    private var growth: UnsafeMutablePointer<Float>

    /// Direction of gravity in screen coordinates (y down); its length scales the strength.
    public var gravity = SIMD2<Float>(0, 1)
    /// Extra acceleration felt by everything in the tank, pt/s² (the negative of the tank's own acceleration).
    public var push = SIMD2<Float>(0, 0)
    /// 0…1: extra friction that lets the water come to a real stop when nothing disturbs it (so it can sleep
    /// without freezing mid-motion).
    public var calming: Float = 0

    private var bodyStates: [BodyState] = []
    /// Poses of the floating bodies, in the order they were added.
    public var bodies: [Body] { bodyStates.map(\.pose) }
    private var bodyParticleCount = 0
    /// Per body particle (index − count): which body it belongs to, and how wet it is.
    private var bodyOf: [Int] = []
    private var bodyWetness: [Float] = []
    private var wetScratch: [Float] = []
    private var dynamic: Int { count + bodyParticleCount }
    private var total = 0
    private var capacity = 0

    private let h: Float
    public let restDensity: Float
    private let cellSize: Float
    private var columns = 1, rows = 1
    private var cellStart: UnsafeMutablePointer<Int32>
    private var cellFill: UnsafeMutablePointer<Int32>
    private var cellCapacity = 0
    private var cellOf: UnsafeMutablePointer<Int32>
    private var sorted: UnsafeMutablePointer<Int32>
    private static let maxNeighbours = 40
    private var neighbours: UnsafeMutablePointer<Int32>
    private var neighbourCount: UnsafeMutablePointer<Int32>
    private var density: UnsafeMutablePointer<Float>
    private var lambda: UnsafeMutablePointer<Float>
    private var dvx: UnsafeMutablePointer<Float>
    private var dvy: UnsafeMutablePointer<Float>
    private var gradient: UnsafeMutablePointer<Float>

    public init(width: Float, height: Float, fillTo level: Float, parameters: Parameters = .init()) {
        self.parameters = parameters
        self.width = width
        self.height = height
        h = parameters.spacing * parameters.radiusFactor
        cellSize = h
        restDensity = Self.latticeDensity(spacing: parameters.spacing, radius: h)
        let (xs, ys) = Self.lattice(width: width, height: height, level: level, parameters: parameters)
        count = xs.count
        x = .allocate(capacity: 1); y = .allocate(capacity: 1); vx = .allocate(capacity: 1); vy = .allocate(capacity: 1)
        px = .allocate(capacity: 1); py = .allocate(capacity: 1); inverseMass = .allocate(capacity: 1)
        weight = .allocate(capacity: 1); growth = .allocate(capacity: 1)
        density = .allocate(capacity: 1); lambda = .allocate(capacity: 1); dvx = .allocate(capacity: 1)
        dvy = .allocate(capacity: 1); gradient = .allocate(capacity: 2)
        cellOf = .allocate(capacity: 1); sorted = .allocate(capacity: 1); neighbourCount = .allocate(capacity: 1)
        neighbours = .allocate(capacity: 1)
        cellStart = .allocate(capacity: 1); cellFill = .allocate(capacity: 1)
        reserve(count + wallParticleCount())
        for i in 0..<count {
            x[i] = xs[i]; y[i] = ys[i]; px[i] = xs[i]; py[i] = ys[i]; vx[i] = 0; vy[i] = 0; inverseMass[i] = 1
            weight[i] = 1; growth[i] = 0
        }
        placeWalls()
        layoutGrid()
        buildGrid()
    }

    deinit {
        for p in [x, y, vx, vy, px, py, inverseMass, weight, growth, density, lambda, dvx, dvy, gradient] { p.deallocate() }
        for p in [cellOf, sorted, neighbourCount, neighbours, cellStart, cellFill] { p.deallocate() }
    }

    /// Water laid out in a hexagonal lattice from the bottom up to `level`.
    private static func lattice(width: Float, height: Float, level: Float, parameters: Parameters) -> ([Float], [Float]) {
        let s = parameters.spacing * parameters.packing
        let rowHeight = s * 0.866
        var xs: [Float] = [], ys: [Float] = []
        var row = 0
        var yy = height - s / 2
        while yy > level {
            var xx = s / 2 + (row & 1 == 0 ? 0 : s / 2)
            while xx < width - s / 4 {
                xs.append(xx + .random(in: -0.2...0.2))
                ys.append(yy)
                xx += s
            }
            yy -= rowHeight
            row += 1
        }
        return (xs, ys)
    }

    /// How many water particles fill a tank of this size up to `level`.
    public static func particleCount(width: Float, height: Float, level: Float, parameters: Parameters = .init()) -> Int {
        lattice(width: width, height: height, level: level, parameters: parameters).0.count
    }

    // MARK: Bodies

    /// Puts a floating box into the water and returns its index. `density` is relative to water (below 1 floats).
    /// Water particles it lands on are moved out of its way. `extent` is the half-size of what is drawn for it (when
    /// larger than the solid box): the walls keep all of that inside, however the body turns.
    @discardableResult
    public func addBody(center: SIMD2<Float>, halfSize: SIMD2<Float>, extent: SIMD2<Float>? = nil, angle: Float = 0,
                        density: Float = 0.42) -> Int {
        let s = parameters.spacing * 0.95
        let columnsOfBody = max(Int((2 * halfSize.x / s).rounded()), 1)
        let rowsOfBody = max(Int((2 * halfSize.y / s).rounded()), 1)
        var offsets: [SIMD2<Float>] = []
        for row in 0..<rowsOfBody {
            for column in 0..<columnsOfBody {
                let ox = (Float(column) + 0.5) / Float(columnsOfBody) * 2 * halfSize.x - halfSize.x
                let oy = (Float(row) + 0.5) / Float(rowsOfBody) * 2 * halfSize.y - halfSize.y
                offsets.append(SIMD2(ox, oy))
            }
        }
        reserve(dynamic + offsets.count + wallParticleCount())
        let start = dynamic
        let index = bodyStates.count
        let c = cos(angle), sn = sin(angle)
        for (k, offset) in offsets.enumerated() {
            let i = start + k
            x[i] = center.x + offset.x * c - offset.y * sn
            y[i] = center.y + offset.x * sn + offset.y * c
            px[i] = x[i]; py[i] = y[i]; vx[i] = 0; vy[i] = 0
            inverseMass[i] = 1
            weight[i] = 1; growth[i] = 0
        }
        bodyStates.append(BodyState(
            offsets: offsets, start: start, columns: columnsOfBody, lift: 1 / max(density, 0.05) - 1,
            extent: pointwiseMax(extent ?? halfSize, halfSize),
            pose: Body(center: center, angle: angle, velocity: .zero, halfSize: halfSize)
        ))
        bodyParticleCount += offsets.count
        bodyOf += Array(repeating: index, count: offsets.count)
        bodyWetness += Array(repeating: 0, count: offsets.count)
        wetScratch += Array(repeating: 0, count: offsets.count)
        // Clear water out of the box.
        let reach = halfSize + parameters.spacing * 0.5
        for i in 0..<count {
            let dx = x[i] - center.x, dy = y[i] - center.y
            let lx = dx * c + dy * sn, ly = -dx * sn + dy * c
            guard abs(lx) < reach.x, abs(ly) < reach.y else { continue }
            let outY = ly < 0 ? -reach.y : reach.y
            x[i] = center.x + lx * c - outY * sn
            y[i] = center.y + lx * sn + outY * c
            px[i] = x[i]; py[i] = y[i]
        }
        placeWalls()
        return index
    }

    // MARK: Adding and removing water

    /// How long a new particle takes to reach its full weight (or a removed one to fade away), seconds.
    private static let growTime: Float = 0.6

    /// Water particles not on their way out: what the tank holds once everything has settled.
    public var waterAmount: Int { count - shrinking }
    private var shrinking = 0

    /// Adds water inside the body of water, next to random particles. Each new particle starts weightless and
    /// grows to full weight in a moment, so the water swells evenly instead of popping (and nothing depends on
    /// where the surface is free of floating things).
    public func addWater(_ amount: Int) {
        guard amount > 0, count > 0 else { return }
        reserve(dynamic + amount + wallParticleCount())
        // Move the bodies' particles up to make room.
        if bodyParticleCount > 0 {
            for p in [x, y, vx, vy, px, py, inverseMass, weight, growth] {
                memmove(p + count + amount, p + count, bodyParticleCount * MemoryLayout<Float>.stride)
            }
            for index in bodyStates.indices { bodyStates[index].start += amount }
        }
        let s = parameters.spacing
        for k in 0..<amount {
            let i = count + k
            var source = Int.random(in: 0..<count)
            // Prefer settled water to a flying drop.
            for _ in 0..<4 where weight[source] < 1 || growth[source] < 0 { source = Int.random(in: 0..<count) }
            let angle = Float.random(in: 0...(2 * .pi))
            x[i] = min(max(x[source] + cos(angle) * s * 0.5, 1), width - 1)
            y[i] = min(max(y[source] + sin(angle) * s * 0.5, 1), height - 1)
            vx[i] = vx[source]; vy[i] = vy[source]
            px[i] = x[i]; py[i] = y[i]
            inverseMass[i] = 1
            weight[i] = 0
            growth[i] = 1
        }
        count += amount
        placeWalls()
    }

    /// Takes water away: random particles fade to nothing over a moment (the rest closes up gently), then go.
    public func removeWater(_ amount: Int) {
        let amount = min(amount, max(waterAmount - 20, 0))
        guard amount > 0 else { return }
        var marked = 0
        var tries = 0
        while marked < amount, tries < amount * 20 {
            tries += 1
            let i = Int.random(in: 0..<count)
            guard growth[i] >= 0 else { continue }
            growth[i] = -1
            marked += 1
        }
        shrinking += marked
    }

    /// Grows new particles and fades removed ones; drops those that have faded out.
    private func updateWeights(_ dt: Float) {
        let rate = dt / Self.growTime
        var gone: [Int] = []
        for i in 0..<count where growth[i] != 0 {
            weight[i] = min(max(weight[i] + growth[i] * rate, 0), 1)
            if growth[i] > 0, weight[i] >= 1 { growth[i] = 0 }
            if growth[i] < 0, weight[i] <= 0 { gone.append(i) }
        }
        guard !gone.isEmpty else { return }
        // Highest index first, so moving the last particle into a hole never moves one still to be removed.
        for hole in gone.sorted(by: >) {
            let last = count - 1
            for p in [x, y, vx, vy, px, py, weight, growth] { p[hole] = p[last] }
            count -= 1
        }
        shrinking -= gone.count
        if bodyParticleCount > 0 {
            for p in [x, y, vx, vy, px, py, inverseMass, weight, growth] {
                memmove(p + count, p + count + gone.count, bodyParticleCount * MemoryLayout<Float>.stride)
            }
            for index in bodyStates.indices { bodyStates[index].start -= gone.count }
        }
        placeWalls()
    }

    // MARK: Buffers

    private func wallParticleCount() -> Int {
        let s = parameters.spacing
        let along = Int((width + 4 * s) / s) + 2, down = Int((height + 4 * s) / s) + 2
        return 2 * 2 * (along + down)
    }

    /// Grows every per-particle buffer to hold `needed` particles (with room to spare), keeping moving particles.
    private func reserve(_ needed: Int) {
        guard needed > capacity else { return }
        let size = needed + needed / 4
        let keep = capacity > 0 ? dynamic : 0
        func grow(_ p: inout UnsafeMutablePointer<Float>, _ size: Int, keep: Int) {
            let fresh = UnsafeMutablePointer<Float>.allocate(capacity: size)
            fresh.initialize(repeating: 0, count: size)
            if keep > 0 { fresh.update(from: p, count: keep) }
            p.deallocate()
            p = fresh
        }
        func growIndex(_ p: inout UnsafeMutablePointer<Int32>, _ size: Int) {
            let fresh = UnsafeMutablePointer<Int32>.allocate(capacity: size)
            fresh.initialize(repeating: 0, count: size)
            p.deallocate()
            p = fresh
        }
        grow(&x, size, keep: keep); grow(&y, size, keep: keep); grow(&vx, size, keep: keep); grow(&vy, size, keep: keep)
        grow(&px, size, keep: keep); grow(&py, size, keep: keep); grow(&inverseMass, size, keep: keep)
        grow(&weight, size, keep: keep); grow(&growth, size, keep: keep)
        grow(&density, size, keep: 0); grow(&lambda, size, keep: 0); grow(&dvx, size, keep: 0); grow(&dvy, size, keep: 0)
        grow(&gradient, size * 2, keep: 0)
        growIndex(&cellOf, size); growIndex(&sorted, size); growIndex(&neighbourCount, size)
        growIndex(&neighbours, size * Self.maxNeighbours)
        capacity = size
    }

    /// Two rows of fixed particles just outside each wall.
    private func placeWalls() {
        let s = parameters.spacing
        var index = dynamic
        func add(_ wx: Float, _ wy: Float) {
            x[index] = wx; y[index] = wy; px[index] = wx; py[index] = wy; vx[index] = 0; vy[index] = 0
            inverseMass[index] = 0
            weight[index] = 1; growth[index] = 0
            index += 1
        }
        for layer in 0..<2 {
            let offset = s * (0.5 + Float(layer) * 0.866)
            var along = -offset
            while along <= width + offset {
                add(along, -offset)
                add(along, height + offset)
                along += s
            }
            var down = -offset + s
            while down < height + offset {
                add(-offset, down)
                add(width + offset, down)
                down += s
            }
        }
        total = index
    }

    /// Density one particle sees in a hexagonal lattice at the given spacing (itself included): the rest density.
    private static func latticeDensity(spacing: Float, radius: Float) -> Float {
        var total: Float = 0
        let rowHeight = spacing * 0.866
        for row in -6...6 {
            for column in -6...6 {
                let dx = Float(column) * spacing + (row & 1 == 0 ? 0 : spacing / 2)
                let dy = Float(row) * rowHeight
                let r = (dx * dx + dy * dy).squareRoot()
                guard r < radius else { continue }
                total += spiky(r, radius)
            }
        }
        return total
    }

    /// Unnormalised spiky kernel ((h − r) / h)³; its gradient 3(h − r)² / h³ is used with it, so constraint steps are
    /// exact Newton steps and the water does not overshoot and tremble.
    @inline(__always)
    static func spiky(_ r: Float, _ h: Float) -> Float {
        let d = (h - r) / h
        return d * d * d
    }

    /// Unnormalised 2D poly6 kernel: ((h² − r²) / h²)³.
    @inline(__always)
    static func poly6(_ r2: Float, _ h2: Float) -> Float {
        let d = (h2 - r2) / h2
        return d * d * d
    }

    @inline(__always)
    static func smoothstep(_ from: Float, _ to: Float, _ value: Float) -> Float {
        let t = min(max((value - from) / (to - from), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Keeps the particles when the tank changes size (the walls squeeze or free them).
    public func resize(width newWidth: Float, height newHeight: Float) {
        guard newWidth != width || newHeight != height else { return }
        width = newWidth
        height = newHeight
        reserve(dynamic + wallParticleCount())
        for i in 0..<dynamic {
            x[i] = min(max(x[i], 1), width - 1)
            y[i] = min(max(y[i], 1), height - 1)
        }
        placeWalls()
        layoutGrid()
        buildGrid()
    }

    private func layoutGrid() {
        columns = max(Int((width / cellSize).rounded(.up)) + 2, 1)
        rows = max(Int((height / cellSize).rounded(.up)) + 2, 1)
        let needed = columns * rows + 1
        if needed > cellCapacity {
            cellStart.deallocate()
            cellFill.deallocate()
            cellStart = .allocate(capacity: needed)
            cellFill = .allocate(capacity: needed)
            cellCapacity = needed
        }
    }

    // MARK: Stepping

    private var leftover: Float = 0

    /// Advances by `seconds` (at most a few substeps per call). Returns the mean and the fastest water speed, pt/s.
    @discardableResult
    public func step(seconds: Float) -> (typical: Float, fastest: Float) {
        let dt = 1 / parameters.substepsPerSecond
        leftover += min(seconds, 4 * dt)
        var result: (Float, Float) = (0, 0)
        while leftover >= dt {
            leftover -= dt
            result = substep(dt)
        }
        return result
    }

    private func substep(_ dt: Float) -> (Float, Float) {
        let n = dynamic
        let g = (gravity * parameters.gravityStrength + push) * dt * dt
        buildGrid()                                      // for the depth probes below
        applyLift(dt)
        for i in 0..<n {
            vx[i] += g.x
            vy[i] += g.y
            px[i] = x[i]; py[i] = y[i]
            x[i] += vx[i]
            y[i] += vy[i]
            if !x[i].isFinite || !y[i].isFinite { x[i] = px[i]; y[i] = py[i]; vx[i] = 0; vy[i] = 0 }
        }
        buildGrid()
        buildNeighbours()
        for _ in 0..<parameters.iterations {
            solveDensity()
            collideWalls()
            matchBodyShapes()
            keepBodiesInside()
        }

        let limit = parameters.spacing * 1.2          // nothing jumps much more than a spacing per substep
        let keep = pow(parameters.damping * (1 - 0.95 * min(max(calming, 0), 1)), dt)
        var fastest: Float = 0, sum: Float = 0
        for i in 0..<n {
            if !x[i].isFinite || !y[i].isFinite { x[i] = px[i]; y[i] = py[i] }
            var dx = x[i] - px[i], dy = y[i] - py[i]
            let speed = abs(dx) + abs(dy)
            if speed > limit {
                dx *= limit / speed; dy *= limit / speed
                x[i] = px[i] + dx; y[i] = py[i] + dy
            }
            vx[i] = dx * keep
            vy[i] = dy * keep
            if i < count {
                fastest = max(fastest, speed)
                sum += speed
            }
        }
        applyViscosity()
        updateBodyStates()
        updateWeights(dt)
        let perSecond = parameters.substepsPerSecond
        return (sum / Float(max(count, 1)) * perSecond, fastest * perSecond)
    }

    /// Archimedes on the bodies, per particle: only the part under water is lifted (that also rights them).
    /// Near the surface a body floats by its density and dives when it falls in; deep down the push grows several
    /// times, so it shoots back up instead of creeping through the water.
    private func applyLift(_ dt: Float) {
        for body in bodyStates {
            let depth = depthOf(body.pose)
            let boost = Self.smoothstep(20, 80, depth)
            let factor = body.lift + (parameters.deepLift - body.lift) * boost
            for k in 0..<body.offsets.count {
                let i = body.start + k
                let wet = bodyWetness[i - count]
                let lift = -gravity * parameters.gravityStrength * dt * dt * factor * wet
                vx[i] += lift.x
                vy[i] += lift.y
                // Water drag on the submerged part.
                let drag = 1 - 0.03 * wet
                vx[i] *= drag
                vy[i] *= drag
            }
            // Speed limit for the body as a whole (its particles share one velocity after shape matching).
            let m = body.offsets.count
            var mean = SIMD2<Float>(0, 0)
            for k in 0..<m { mean += SIMD2(vx[body.start + k], vy[body.start + k]) }
            mean /= Float(m)
            let speed = (mean.x * mean.x + mean.y * mean.y).squareRoot()
            let limit = parameters.bodySpeedLimit * dt
            if speed > limit {
                let excess = mean * (1 - limit / speed)
                for k in 0..<m {
                    vx[body.start + k] -= excess.x
                    vy[body.start + k] -= excess.y
                }
            }
        }
    }

    /// How far below the surface a body's centre is (0 when not under water), probing against gravity.
    private func depthOf(_ body: Body) -> Float {
        let length = (gravity.x * gravity.x + gravity.y * gravity.y).squareRoot()
        guard length > 0.05 else { return 0 }
        let up = -gravity / length
        var depth: Float = 0
        let step = parameters.spacing
        while depth < 120 {
            let probe = body.center + up * (depth + body.halfSize.y + step)
            if probe.x < 0 || probe.y < 0 || probe.x > width || probe.y > height { break }
            guard wetness(at: probe).0 > 0.3 else { break }
            depth += step
        }
        return depth
    }

    @inline(__always)
    private func cell(_ value: Float, _ limit: Int) -> Int {
        // One spare cell on each side holds the wall particles just outside the tank.
        let scaled = value / cellSize + 1
        guard scaled.isFinite else { return 0 }
        return Int(min(max(scaled, 0), Float(limit - 1)))
    }

    /// Counting sort of all particles (walls too) by cell.
    private func buildGrid() {
        let cells = columns * rows
        cellStart.update(repeating: 0, count: cells + 1)
        for i in 0..<total {
            let c = cell(y[i], rows) * columns + cell(x[i], columns)
            cellOf[i] = Int32(c)
            cellStart[c + 1] += 1
        }
        for c in 0..<cells { cellStart[c + 1] += cellStart[c] }
        cellFill.update(from: cellStart, count: cells)
        for i in 0..<total {
            let c = Int(cellOf[i])
            sorted[Int(cellFill[c])] = Int32(i)
            cellFill[c] += 1
        }
    }

    /// For each moving particle, the particles after it within reach (each pair once; walls come last).
    private func buildNeighbours() {
        let h2 = h * h
        let n = dynamic
        for i in 0..<n {
            let xi = x[i], yi = y[i]
            let list = neighbours + i * Self.maxNeighbours
            var found = 0
            let cx = cell(xi, columns), cy = cell(yi, rows)
            let ownBody = i >= count ? bodyOf[i - count] : -1
            rowsLoop: for yy in max(cy - 1, 0)...min(cy + 1, rows - 1) {
                let base = yy * columns
                var k = Int(cellStart[base + max(cx - 1, 0)])
                let end = Int(cellStart[base + min(cx + 1, columns - 1) + 1])
                while k < end {
                    let j = Int(sorted[k])
                    k += 1
                    guard j > i else { continue }
                    // Particles of the same rigid body do not push each other.
                    if ownBody >= 0, j < n, bodyOf[j - count] == ownBody { continue }
                    let dx = x[j] - xi, dy = y[j] - yi
                    if dx * dx + dy * dy < h2 {
                        list[found] = Int32(j)
                        found += 1
                        if found == Self.maxNeighbours { break rowsLoop }
                    }
                }
            }
            neighbourCount[i] = Int32(found)
        }
    }

    /// One PBF pass: densities, constraint multipliers λ, then position corrections.
    /// Only compression is corrected (one-sided constraint), so surfaces and drops stay free.
    private func solveDensity() {
        let n = dynamic
        let h2 = h * h
        let invRest = 1 / restDensity
        let gradScale: Float = 3 / (h * h * h)
        for i in 0..<n { density[i] = weight[i] }             // itself
        for k in wetScratch.indices { wetScratch[k] = 0 }
        lambda.update(repeating: 0, count: n)                  // Σ wₖ|∇ₖCᵢ|² over neighbours first
        gradient.update(repeating: 0, count: n * 2)            // ∇ᵢCᵢ
        for i in 0..<n {
            let list = neighbours + i * Self.maxNeighbours
            let xi = x[i], yi = y[i]
            let wi = inverseMass[i]
            for k in 0..<Int(neighbourCount[i]) {
                let j = Int(list[k])
                let dx = xi - x[j], dy = yi - y[j]
                let r2 = dx * dx + dy * dy
                guard r2 < h2 else { continue }
                let r = r2.squareRoot()
                let w = Self.spiky(r, h)
                let moving = j < n
                // Each neighbour counts by its weight (new water grows in, removed water fades out).
                let weightI = weight[i], weightJ = weight[j]
                density[i] += w * weightJ
                if moving { density[j] += w * weightI }
                if i < count, j >= count, moving { wetScratch[j - count] += w * weightI }
                guard r2 > 1e-8 else { continue }
                let t = h - r
                let magnitude = gradScale * t * t / r * invRest
                let gx = dx * magnitude, gy = dy * magnitude
                let g2 = gx * gx + gy * gy
                gradient[2 * i] += gx * weightJ; gradient[2 * i + 1] += gy * weightJ
                guard moving else { continue }
                lambda[i] += inverseMass[j] * g2 * weightJ * weightJ
                lambda[j] += wi * g2 * weightI * weightI
                gradient[2 * j] -= gx * weightI; gradient[2 * j + 1] -= gy * weightI
            }
        }
        // Only a body's outer rows touch water (an outer particle under water sees about a third of the rest
        // density from it); inner rows are as wet as the two outer rows of their column on average. So a body that
        // only dips its edge in gets a little lift, and a submerged one the full lift.
        for body in bodyStates {
            let base = body.start - count
            let rowsOfBody = body.offsets.count / body.columns
            for column in 0..<body.columns {
                let first = min(wetScratch[base + column] / (restDensity * 0.3), 1)
                let last = min(wetScratch[base + (rowsOfBody - 1) * body.columns + column] / (restDensity * 0.3), 1)
                for row in 0..<rowsOfBody {
                    let k = base + row * body.columns + column
                    bodyWetness[k] = row == 0 ? first : (row == rowsOfBody - 1 ? last : (first + last) / 2)
                }
            }
        }
        let epsilon = parameters.relaxation * gradScale * gradScale * h2 * invRest * invRest
        for i in 0..<n {
            let constraint = max(density[i] * invRest - 1, 0)
            let gx = gradient[2 * i], gy = gradient[2 * i + 1]
            let sum = lambda[i] + inverseMass[i] * (gx * gx + gy * gy)
            lambda[i] = -constraint / (sum + epsilon)
        }
        let tensile = parameters.tensileStrength
        let reference = Self.poly6(0.09 * h2, h2)                  // Δq = 0.3h
        dvx.update(repeating: 0, count: n)
        dvy.update(repeating: 0, count: n)
        for i in 0..<n {
            let list = neighbours + i * Self.maxNeighbours
            let xi = x[i], yi = y[i]
            for k in 0..<Int(neighbourCount[i]) {
                let j = Int(list[k])
                let dx = xi - x[j], dy = yi - y[j]
                let r2 = dx * dx + dy * dy
                guard r2 < h2, r2 > 1e-8 else { continue }
                let r = r2.squareRoot()
                let t = h - r
                let ratio = Self.poly6(r2, h2) / reference
                let correction = -tensile * ratio * ratio * ratio * ratio
                let lambdaJ = j < n ? lambda[j] : 0
                // ∇W(xᵢ − xⱼ) points from i towards j, hence the minus: with λ < 0 (compressed) the pair separates.
                // Light (growing or fading) particles push and are pushed only as much as they weigh.
                let pairWeight = min(weight[i], weight[j])
                let scale = -(lambda[i] + lambdaJ + correction) * gradScale * t * t / r * invRest * pairWeight
                let sx = dx * scale, sy = dy * scale
                dvx[i] += sx; dvy[i] += sy
                if j < n { dvx[j] -= sx; dvy[j] -= sy }
            }
        }
        for i in 0..<n {
            let w = inverseMass[i]
            x[i] += dvx[i] * w
            y[i] += dvy[i] * w
        }
    }

    private func collideWalls() {
        let margin = parameters.spacing * 0.3
        for i in 0..<dynamic {
            // Water drags a little along the walls; floating bodies slide freely.
            let friction: Float = i < count ? 0.05 : 0
            if x[i] < margin { x[i] = margin; y[i] -= (y[i] - py[i]) * friction }
            if x[i] > width - margin { x[i] = width - margin; y[i] -= (y[i] - py[i]) * friction }
            if y[i] < margin { y[i] = margin; x[i] -= (x[i] - px[i]) * friction }
            if y[i] > height - margin { y[i] = height - margin; x[i] -= (x[i] - px[i]) * friction }
        }
    }

    /// Moves a body back in when its drawn box, turned as it is, crosses a wall (its particles alone sit well inside
    /// that box, so the walls of `collideWalls` would let the edges and corners through).
    private func keepBodiesInside() {
        let inset: Float = 2
        for index in bodyStates.indices {
            let body = bodyStates[index]
            let c = abs(cos(body.pose.angle)), s = abs(sin(body.pose.angle))
            let reach = SIMD2(c * body.extent.x + s * body.extent.y, s * body.extent.x + c * body.extent.y) + inset
            func limited(_ value: Float, _ reach: Float, _ size: Float) -> Float {
                reach * 2 >= size ? size / 2 : min(max(value, reach), size - reach)
            }
            let center = body.pose.center
            let shift = SIMD2(limited(center.x, reach.x, width), limited(center.y, reach.y, height)) - center
            guard shift != .zero else { continue }
            for k in 0..<body.offsets.count {
                x[body.start + k] += shift.x
                y[body.start + k] += shift.y
            }
            bodyStates[index].pose.center = center + shift
        }
    }

    /// Snaps each body's particles back to a rigid box: the best-fit translation and rotation (shape matching).
    private func matchBodyShapes() {
        for index in bodyStates.indices {
            let body = bodyStates[index]
            let m = body.offsets.count
            var center = SIMD2<Float>(0, 0)
            for k in 0..<m { center += SIMD2(x[body.start + k], y[body.start + k]) }
            center /= Float(m)
            var dot: Float = 0, cross: Float = 0
            for k in 0..<m {
                let p = SIMD2(x[body.start + k], y[body.start + k]) - center
                let q = body.offsets[k]
                dot += q.x * p.x + q.y * p.y
                cross += q.x * p.y - q.y * p.x
            }
            let angle = atan2(cross, dot)
            let c = cos(angle), s = sin(angle)
            for k in 0..<m {
                let q = body.offsets[k]
                x[body.start + k] = center.x + q.x * c - q.y * s
                y[body.start + k] = center.y + q.x * s + q.y * c
            }
            bodyStates[index].pose.center = center
            bodyStates[index].pose.angle = angle
        }
    }

    private func updateBodyStates() {
        for index in bodyStates.indices {
            let body = bodyStates[index]
            var velocity = SIMD2<Float>(0, 0)
            for k in 0..<body.offsets.count { velocity += SIMD2(vx[body.start + k], vy[body.start + k]) }
            bodyStates[index].pose.velocity = velocity / Float(body.offsets.count) * parameters.substepsPerSecond
        }
    }

    /// XSPH: each water particle's velocity moves a little towards its neighbours' (smooth, calm flow).
    private func applyViscosity() {
        let c = parameters.viscosity
        guard c > 0 else { return }
        let h2 = h * h
        dvx.update(repeating: 0, count: count)
        dvy.update(repeating: 0, count: count)
        for i in 0..<count {
            let list = neighbours + i * Self.maxNeighbours
            for k in 0..<Int(neighbourCount[i]) {
                let j = Int(list[k])
                guard j < count else { continue }
                let dx = x[j] - x[i], dy = y[j] - y[i]
                let r2 = dx * dx + dy * dy
                guard r2 < h2 else { continue }
                let w = Self.poly6(r2, h2) * c
                let ux = (vx[j] - vx[i]) * w, uy = (vy[j] - vy[i]) * w
                dvx[i] += ux; dvy[i] += uy
                dvx[j] -= ux; dvy[j] -= uy
            }
        }
        for i in 0..<count {
            vx[i] += dvx[i] * 0.5
            vy[i] += dvy[i] * 0.5
        }
    }

    // MARK: Queries and pokes

    /// How much water is at a point (0…1) and its average velocity (pt/s).
    public func wetness(at point: SIMD2<Float>) -> (Float, SIMD2<Float>) {
        var sum: Float = 0
        var flow = SIMD2<Float>(0, 0)
        let perSecond = parameters.substepsPerSecond
        let cx = cell(point.x, columns), cy = cell(point.y, rows)
        for yy in max(cy - 1, 0)...min(cy + 1, rows - 1) {
            let base = yy * columns
            var k = Int(cellStart[base + max(cx - 1, 0)])
            let end = Int(cellStart[base + min(cx + 1, columns - 1) + 1])
            while k < end {
                let j = Int(sorted[k])
                k += 1
                guard j < count else { continue }
                let dx = x[j] - point.x, dy = y[j] - point.y
                let r = (dx * dx + dy * dy).squareRoot()
                guard r < h else { continue }
                let w = Self.spiky(r, h) * weight[j]
                sum += w
                flow += SIMD2(vx[j], vy[j]) * perSecond * w
            }
        }
        guard sum > 0 else { return (0, .zero) }
        return (min(sum / (restDensity * 0.5), 1), flow / sum)
    }

    /// Gives water near a point a kick (pt/s), e.g. a drop falling in or a click.
    public func kick(at point: SIMD2<Float>, radius: Float, velocity: SIMD2<Float>) {
        let perSubstep = velocity / parameters.substepsPerSecond
        for i in 0..<count {
            let dx = x[i] - point.x, dy = y[i] - point.y
            let d2 = dx * dx + dy * dy
            guard d2 < radius * radius else { continue }
            let falloff = 1 - d2.squareRoot() / radius
            vx[i] += perSubstep.x * falloff
            vy[i] += perSubstep.y * falloff
        }
    }

    /// Pushes a floating body at a point (pt/s), e.g. a bubble hitting it: it moves and turns.
    public func nudgeBody(_ index: Int, at point: SIMD2<Float>, velocity: SIMD2<Float>) {
        guard bodyStates.indices.contains(index) else { return }
        let body = bodyStates[index]
        let perSubstep = velocity / parameters.substepsPerSecond
        let arm = point - body.pose.center
        let reach = max(body.pose.halfSize.x * body.pose.halfSize.x, 1)
        // Angular part: v = ω × r, with ω from the off-centre push.
        let spin = (arm.x * perSubstep.y - arm.y * perSubstep.x) / reach
        for k in 0..<body.offsets.count {
            let i = body.start + k
            let r = SIMD2(x[i], y[i]) - body.pose.center
            vx[i] += perSubstep.x - spin * r.y
            vy[i] += perSubstep.y + spin * r.x
        }
    }
}
