import FluidKit
import Foundation
import Testing

@Suite("Water")
struct FluidSimTests {
    /// A badge thrown at the walls: its drawn box, turned as it is, never leaves the tank.
    @Test func aFloatingBoxStaysInsideTheTank() {
        let width: Float = 220, height: Float = 600
        let sim = FluidSim(width: width, height: height, fillTo: 380)
        let drawn = SIMD2<Float>(40, 11)
        let index = sim.addBody(center: SIMD2(170, 370), halfSize: drawn - SIMD2(5, 3), extent: drawn)
        for gravity in [SIMD2<Float>(1, 0.2), SIMD2(-1, 0.3), SIMD2(0.7, -0.7), SIMD2(1, 1)] {
            sim.gravity = gravity
            for _ in 0..<240 {
                _ = sim.step(seconds: 1 / 60)
                let body = sim.bodies[index]
                let c = abs(cos(body.angle)), s = abs(sin(body.angle))
                let reach = SIMD2(c * drawn.x + s * drawn.y, s * drawn.x + c * drawn.y)
                #expect(body.center.x - reach.x >= -0.5 && body.center.x + reach.x <= width + 0.5)
                #expect(body.center.y - reach.y >= -0.5 && body.center.y + reach.y <= height + 0.5)
            }
        }
    }
}
