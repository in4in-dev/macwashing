import CoreGraphics
import Foundation
import IOKit.ps

/// What auto-clean asks the system before a run: the power source, the battery, Low Power Mode and whether the
/// displays are on (a dark wake or a Mac left idle with the screen off is not «in use»).
enum PowerState {
    struct Snapshot {
        let onBattery: Bool
        let batteryPercent: Int?
        let lowPowerMode: Bool
    }

    static func current() -> Snapshot {
        var onBattery = false
        var percent: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
            onBattery = type == kIOPSBatteryPowerValue
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                percent = current * 100 / max
            }
        }
        return Snapshot(onBattery: onBattery, batteryPercent: percent,
                        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// The main display sleeps (screen off after idle, a dark wake for Power Nap).
    static var displayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
}
