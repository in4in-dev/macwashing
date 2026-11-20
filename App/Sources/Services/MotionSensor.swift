import Foundation
import IOKit.hid
import MacWashingXPC

/// Reads the MacBook's accelerometer (gravity plus shakes, in g) so the sidebar water can stay level with the ground.
/// The sensor is silent until the privileged helper turns it on; it runs only while the app is in front.
@MainActor
final class MotionSensor {
    /// Latest reading in the sensor's axes, in g. x runs along the keyboard, left to right.
    var onSample: ((SIMD3<Double>) -> Void)?

    private var connection: NSXPCConnection?
    private var manager: IOHIDManager?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
        helper { $0.setMotionSensor(enabled: true, reply: Self.logReply) }
        openDevices()
    }

    func stop() {
        guard running else { return }
        running = false
        helper { $0.setMotionSensor(enabled: false, reply: Self.logReply) }
        closeDevices()
        // The helper also switches the sensor off when this connection closes.
        connection?.invalidate()
        connection = nil
    }

    private func helper(_ body: (MacWashingHelperProtocol) -> Void) {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: MacWashingHelperProtocol.self)
            connection.setCodeSigningRequirement(HelperConstants.helperRequirement)
            connection.invalidationHandler = Self.invalidated { [weak self] in self?.connection = nil }
            connection.resume()
            self.connection = connection
        }
        if let proxy = connection?.remoteObjectProxyWithErrorHandler(Self.logError) as? MacWashingHelperProtocol {
            body(proxy)
        }
    }

    // XPC calls these on its own queue: they must not be main-actor closures (that traps at runtime).
    private nonisolated static let logReply: @Sendable (Bool) -> Void = { ok in
        if !ok { NSLog("MacWashing: the helper found no accelerometer") }
    }

    private nonisolated static let logError: @Sendable (any Error) -> Void = { error in
        NSLog("MacWashing: motion sensor helper call failed: %@", error.localizedDescription)
    }

    private nonisolated static func invalidated(_ body: @escaping @MainActor () -> Void) -> @Sendable () -> Void {
        { Task { @MainActor in body() } }
    }

    private func openDevices() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Vendor page 0xFF00, usage 3: the accelerometer behind the SPU.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let context = Unmanaged.passUnretained(self).toOpaque()
        for device in devices {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            buffers.append(buffer)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
                // x, y, z: little-endian Int32 at 6, 10 and 14, in 1/65536 g.
                guard let context, length >= 18 else { return }
                func axis(_ offset: Int) -> Double {
                    var raw: Int32 = 0
                    memcpy(&raw, report + offset, 4)
                    return Double(Int32(littleEndian: raw)) / 65536
                }
                let sample = SIMD3(axis(6), axis(10), axis(14))
                let sensor = Unmanaged<MotionSensor>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { sensor.onSample?(sample) }
            }, context)
        }
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager
    }

    private func closeDevices() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        buffers.forEach { $0.deallocate() }
        buffers = []
    }
}
