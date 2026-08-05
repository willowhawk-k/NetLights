#if os(Linux)
import Foundation
import NetLightsCore

// L3 power collector: read /sys/class/power_supply/* and hand the raw attributes to the pure
// assembler in Core (PowerParsing.swift). I/O only.
//
// A desktop or a VM has no power_supply directory at all, which is the ordinary case, not an
// error — buildSystemPower returns nil and the battery entity simply doesn't appear.

private let powerRoot = "/sys/class/power_supply"

private let attrs = ["type", "scope", "status", "capacity", "online",
                     "manufacturer", "model_name", "serial_number",
                     "input_power_limit", "voltage_max", "current_max",
                     "energy_now", "energy_full", "charge_now", "charge_full"]

func linuxPowerSupplies() -> [PowerSupplyReading] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: powerRoot)) ?? []).sorted()
    return names.map { name in
        var a: [String: String] = [:]
        for k in attrs {
            if let v = try? String(contentsOfFile: "\(powerRoot)/\(name)/\(k)", encoding: .utf8) {
                a[k] = v
            }
        }
        return PowerSupplyReading(name: name, attributes: a)
    }
}

func linuxSystemPower() -> SystemPower? { buildSystemPower(linuxPowerSupplies()) }
#endif
