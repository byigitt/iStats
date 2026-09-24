import Foundation
import IOKit

struct Accessory: Identifiable {
    let name: String
    let percent: Int
    var id: String { name }

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("keyboard") { return "keyboard" }
        if lower.contains("mouse") { return "magicmouse" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if lower.contains("pencil") { return "applepencil" }
        return "battery.75percent"
    }
}

struct SensorReadings {
    var cpuTemperature: Double?
    var fans: [Double] = []
    var accessories: [Accessory] = []
}

/// SoC temperature (HID sensor hub), fan speeds (SMC) and Bluetooth accessory batteries.
final class SensorsProbe {
    private lazy var temperatures = HIDTemperatures()
    private lazy var smc = SMC()
    private var fanCount: Int?
    private var accessories: [Accessory] = []
    private var accessoriesStamp = 0.0
    private var profilerRunning = false
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    func sample(includeAccessories: Bool) -> SensorReadings {
        var readings = SensorReadings()
        readings.cpuTemperature = temperatures?.dieAverage()
        if let smc {
            if fanCount == nil { fanCount = Int(smc.readNumber("FNum") ?? 0) }
            readings.fans = (0..<(fanCount ?? 0)).compactMap { smc.readNumber("F\($0)Ac") }
        }
        if includeAccessories { refreshAccessoriesIfNeeded() }
        readings.accessories = accessories
        return readings
    }

    private func refreshAccessoriesIfNeeded() {
        let now = MachTime.seconds
        guard now - accessoriesStamp > 60 || accessoriesStamp == 0, !profilerRunning else { return }
        accessoriesStamp = now
        var found = Self.hidAccessories()
        profilerRunning = true
        // AirPods only report battery through the Bluetooth profiler.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let airPods = Self.bluetoothAccessories()
            self?.queue.async {
                guard let self else { return }
                for device in airPods where !found.contains(where: { $0.name == device.name }) { found.append(device) }
                self.accessories = found.sorted { $0.name < $1.name }
                self.profilerRunning = false
            }
        }
        accessories = found
    }

    private static func hidAccessories() -> [Accessory] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [Accessory] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int,
                  let name = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  !result.contains(where: { $0.name == name })
            else { continue }
            result.append(Accessory(name: name, percent: percent))
        }
        return result
    }

    private static func bluetoothAccessories() -> [Accessory] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }
        var result: [Accessory] = []
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let levels = ["device_batteryLevelMain", "device_batteryLevelLeft", "device_batteryLevelRight"]
                        .compactMap { (info[$0] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) } }
                    if let lowest = levels.min() { result.append(Accessory(name: name, percent: lowest)) }
                }
            }
        }
        return result
    }
}

// MARK: - HID temperature sensors

private typealias HIDClient = OpaquePointer
private typealias HIDService = OpaquePointer
private typealias HIDEvent = OpaquePointer

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> HIDClient?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: HIDClient, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: HIDClient) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: HIDService, _ key: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: HIDService, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: OpaquePointer, _ field: Int32) -> Double

/// Apple Silicon exposes die temperatures through the HID sensor hub (usage page 0xFF00, usage 5).
private final class HIDTemperatures {
    private static let temperatureEvent: Int64 = 15
    private let client: HIDClient
    private let dieSensors: [HIDService]
    private let services: CFArray

    init?() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client) else { return nil }
        self.client = client
        self.services = services
        var dies: [HIDService] = []
        for index in 0..<CFArrayGetCount(services) {
            let service = HIDService(CFArrayGetValueAtIndex(services, index))!
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? ""
            if name.contains("tdie") || name.hasPrefix("pACC") || name.hasPrefix("eACC") { dies.append(service) }
        }
        guard !dies.isEmpty else { return nil }
        dieSensors = dies
    }

    func dieAverage() -> Double? {
        var total = 0.0
        var count = 0
        for service in dieSensors {
            guard let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEvent, 0, 0) else { continue }
            let value = IOHIDEventGetFloatValue(OpaquePointer(event.toOpaque()), Int32(Self.temperatureEvent << 16))
            event.release()
            if value > 0, value < 150 {
                total += value
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }
}

// MARK: - SMC

private final class SMC {
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PowerLimits { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    /// C pads this to 12 bytes; Swift lays out nested structs by size, so the tail padding is explicit.
    private struct KeyInfo { var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0, padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    private struct Parameters {
        var key: UInt32 = 0
        var version = Version()
        var limits = PowerLimits()
        var info = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    func readNumber(_ key: String) -> Double? {
        var input = Parameters()
        input.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        input.command = 9
        guard let info = call(&input) else { return nil }
        input.info.size = info.info.size
        input.command = 5
        guard let output = call(&input) else { return nil }
        return withUnsafeBytes(of: output.bytes) { raw in
            switch info.info.type {
            case 0x666C_7420: Double(raw.loadUnaligned(as: Float.self)) // "flt "
            case 0x7569_3820: Double(raw[0]) // "ui8 "
            case 0x7569_3136: Double(UInt16(raw[0]) << 8 | UInt16(raw[1])) // "ui16"
            case 0x6670_6532: Double(UInt16(raw[0]) << 8 | UInt16(raw[1])) / 4 // "fpe2"
            default: nil
            }
        }
    }

    private func call(_ input: inout Parameters) -> Parameters? {
        var output = Parameters()
        var size = MemoryLayout<Parameters>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Parameters>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }
}
