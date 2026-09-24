import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

// MARK: - CPU

final class CPUProbe {
    private let host = mach_host_self()
    private var previous: (UInt32, UInt32, UInt32, UInt32)?

    let cores = Sysctl.int("hw.ncpu")
    let performanceCores = Sysctl.int("hw.perflevel0.physicalcpu")
    let efficiencyCores = Sysctl.int("hw.perflevel1.physicalcpu")

    /// Returns user (incl. nice) and system load as a percentage of the whole machine.
    func sample() -> (user: Double, system: Double) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let ticks = info.cpu_ticks
        defer { previous = ticks }
        guard let p = previous else { return (0, 0) }
        let user = Double(ticks.0 &- p.0) + Double(ticks.3 &- p.3)
        let system = Double(ticks.1 &- p.1)
        let idle = Double(ticks.2 &- p.2)
        let total = user + system + idle
        guard total > 0 else { return (0, 0) }
        return (user / total * 100, system / total * 100)
    }

    var load: Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }
}

// MARK: - Memory

struct MemoryStats {
    var total = 0.0
    var app = 0.0
    var wired = 0.0
    var compressed = 0.0
    var cached = 0.0
    var swap = 0.0
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level)
    var pressure = 1

    var used: Double { app + wired + compressed }
    var available: Double { max(total - used, 0) }
    var free: Double { max(total - used - cached, 0) }
}

final class MemoryProbe {
    private let host = mach_host_self()
    private let pageSize = Double(Sysctl.int("hw.pagesize"))
    let total = Double(Sysctl.int("hw.memsize"))

    func sample() -> MemoryStats {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var stats = MemoryStats(total: total)
        guard result == KERN_SUCCESS else { return stats }
        let anonymous = Double(vm.internal_page_count)
        let purgeable = Double(vm.purgeable_count)
        stats.app = max(anonymous - purgeable, 0) * pageSize
        stats.wired = Double(vm.wire_count) * pageSize
        stats.compressed = Double(vm.compressor_page_count) * pageSize
        stats.cached = (Double(vm.external_page_count) + purgeable) * pageSize

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            stats.swap = Double(swap.xsu_used)
        }
        stats.pressure = max(Sysctl.int("kern.memorystatus_vm_pressure_level"), 1)
        return stats
    }
}

// MARK: - Disk

struct DiskStats {
    var total = 0.0
    var free = 0.0
    var readRate = 0.0
    var writeRate = 0.0
    var volumes: [String] = []

    var used: Double { max(total - free, 0) }
}

final class DiskProbe {
    /// Cumulative bytes read/written by all block storage drivers since boot.
    func counters() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
        }
        return (read, write)
    }

    func capacity() -> (total: Double, free: Double) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return (0, 0) }
        return (Double(values.volumeTotalCapacity ?? 0), Double(values.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    func volumes() -> [String] {
        // Read-only volumes are almost always mounted disk images, not storage.
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  values.volumeIsReadOnly != true || url.path == "/"
            else { return nil }
            return values.volumeName
        }
    }
}

// MARK: - Network

final class NetworkProbe {
    private var buffer = [UInt8]()
    private var physical: [UInt16: Bool] = [:]
    private var displayNames: [String: String] = [:]
    private let store = SCDynamicStoreCreate(nil, "iStats" as CFString, nil, nil)

    /// Cumulative bytes received/sent on physical (`en*`) interfaces. Uses 64-bit counters.
    func counters() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return (0, 0) }
        if buffer.count < length { buffer = [UInt8](repeating: 0, count: length + 2048) }
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if isPhysical(message.ifm_index) {
                        rx &+= message.ifm_data.ifi_ibytes
                        tx &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    private func isPhysical(_ index: UInt16) -> Bool {
        if let cached = physical[index] { return cached }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        let result = if_indextoname(UInt32(index), &name) != nil
            && name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.hasPrefix("en")
        physical[index] = result
        return result
    }

    /// Primary interface BSD name and user-facing name, e.g. ("en0", "Wi-Fi").
    func primaryInterface() -> (bsd: String, name: String) {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let bsd = global["PrimaryInterface"] as? String
        else { return ("", "Offline") }
        if let cached = displayNames[bsd] { return (bsd, cached) }
        var name = bsd
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in all where (SCNetworkInterfaceGetBSDName(interface) as String?) == bsd {
                name = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? bsd
            }
        }
        if bsd.hasPrefix("utun") { name = "VPN" }
        displayNames[bsd] = name
        return (bsd, name)
    }
}

/// Streams per-process download rates from `nettop`. Only run while the Network tab is visible.
final class NetTop {
    private let queue: DispatchQueue
    private var process: Process?
    private var pending = Data()
    private var current: [Int32: Double] = [:]
    private var headers = 0
    private let interval = 2.0

    var onSample: (([Int32: Double]) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-d", "-x", "-n", "-L", "0", "-s", "\(Int(interval))", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        headers = 0
        current = [:]
        pending.removeAll(keepingCapacity: false)
        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        guard let process else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
        pending.removeAll(keepingCapacity: false)
        current = [:]
    }

    private func consume(_ data: Data) {
        guard process != nil else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            parse(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
        }
    }

    private func parse(_ line: Data) {
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix(",") {
            // Sample header. The first sample is cumulative, later ones are deltas.
            if headers >= 2 { onSample?(current) }
            headers += 1
            current = [:]
            return
        }
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3,
              let dot = fields[0].lastIndex(of: "."),
              let pid = Int32(fields[0][fields[0].index(after: dot)...]),
              let received = Double(fields[1]),
              received > 0
        else { return }
        current[pid] = received / interval
    }
}

// MARK: - GPU

final class GPUProbe {
    private let accelerator: io_registry_entry_t
    private var previousTimes: [Int32: UInt64] = [:]
    private var previousStamp: UInt64 = 0

    let name = Sysctl.string("machdep.cpu.brand_string")

    init() {
        accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    }

    deinit { if accelerator != 0 { IOObjectRelease(accelerator) } }

    func sample() -> (utilization: Double, memory: Double) {
        guard accelerator != 0,
              let stats = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
        else { return (0, 0) }
        let utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0
        let memory = (stats["In use system memory"] as? NSNumber)?.doubleValue ?? 0
        return (utilization, memory)
    }

    /// GPU busy percentage per process, derived from each Metal client's accumulated GPU time.
    func perProcess() -> [Int32: Double] {
        guard accelerator != 0 else { return [:] }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var totals: [Int32: UInt64] = [:]
        while case let client = IOIteratorNext(iterator), client != 0 {
            defer { IOObjectRelease(client) }
            guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  creator.hasPrefix("pid "),
                  let comma = creator.firstIndex(of: ","),
                  let pid = Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]),
                  let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]]
            else { continue }
            var time: UInt64 = 0
            for entry in usage { time &+= (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
            totals[pid, default: 0] &+= time
        }

        let now = mach_absolute_time()
        var result: [Int32: Double] = [:]
        if previousStamp != 0 {
            let elapsed = Double(now - previousStamp) * MachTime.nsPerTick
            for (pid, time) in totals {
                if let before = previousTimes[pid], time > before, elapsed > 0 {
                    result[pid] = min(Double(time - before) / elapsed * 100, 100)
                }
            }
        }
        previousTimes = totals
        previousStamp = now
        return result
    }

    func resetPerProcess() {
        previousTimes = [:]
        previousStamp = 0
    }
}

// MARK: - Battery

struct BatteryStats {
    var present = false
    var percent = 0.0
    var charging = false
    var external = false
    /// Seconds; nil when unknown or not applicable.
    var remaining: Double?
    var toFull: Double?
    var cycles = 0
    var health = 0.0
    var temperature = 0.0
    var watts = 0.0

    var statusText: String {
        if !present { return "No Battery" }
        if charging { return "Charging" }
        return external ? "On Power Adapter" : "On Battery"
    }
}

final class BatteryProbe {
    private let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))

    deinit { if entry != 0 { IOObjectRelease(entry) } }

    private func number(_ key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
    }

    func sample() -> BatteryStats {
        var stats = BatteryStats()
        guard entry != 0, let current = number("CurrentCapacity")?.doubleValue else { return stats }
        stats.present = true
        let max = number("MaxCapacity")?.doubleValue ?? 100
        stats.percent = max > 0 ? min(current / max * 100, 100) : current
        stats.external = number("ExternalConnected")?.boolValue ?? false
        stats.charging = number("IsCharging")?.boolValue ?? false
        stats.cycles = number("CycleCount")?.intValue ?? 0
        stats.temperature = (number("Temperature")?.doubleValue ?? 0) / 100

        let design = number("DesignCapacity")?.doubleValue ?? 0
        let rawMax = number("AppleRawMaxCapacity")?.doubleValue ?? number("NominalChargeCapacity")?.doubleValue ?? 0
        stats.health = design > 0 ? min(rawMax / design * 100, 100) : 0

        let volts = (number("Voltage")?.doubleValue ?? 0) / 1000
        let amps = Double(number("InstantAmperage")?.int64Value ?? number("Amperage")?.int64Value ?? 0) / 1000
        stats.watts = abs(volts * amps)

        let estimate = IOPSGetTimeRemainingEstimate()
        if !stats.external, estimate > 0 { stats.remaining = estimate }
        if stats.charging, let minutes = number("AvgTimeToFull")?.intValue, minutes > 0, minutes < 65535 {
            stats.toFull = Double(minutes) * 60
        }
        return stats
    }
}
