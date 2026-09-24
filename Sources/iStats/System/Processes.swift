import Darwin
import Foundation

struct ProcessSample {
    let pid: Int32
    /// Percent of the whole machine (all cores).
    var cpu = 0.0
    /// Cumulative CPU seconds.
    var cpuTime = 0.0
    var memory = 0.0
    var writeRate = 0.0
    var watts = 0.0
}

final class ProcessProbe {
    private struct Previous {
        var cpu: UInt64
        var write: UInt64
        var energy: UInt64
    }

    private var previous: [Int32: Previous] = [:]
    private var previousStamp = 0.0
    private var pids = [Int32](repeating: 0, count: 4096)
    private let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))

    func sample() -> [ProcessSample] {
        var count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        if count >= pids.count {
            pids = [Int32](repeating: 0, count: count * 2)
            count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        }
        let now = MachTime.seconds
        let elapsed = previousStamp > 0 ? now - previousStamp : 0
        previousStamp = now

        var next: [Int32: Previous] = [:]
        next.reserveCapacity(count)
        var samples: [ProcessSample] = []
        samples.reserveCapacity(count)

        for index in 0..<max(count, 0) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = rusage_info_v6()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard result == 0 else { continue }

            let cpu = info.ri_user_time &+ info.ri_system_time
            let energy = info.ri_energy_nj > 0 ? info.ri_energy_nj : info.ri_billed_energy
            let current = Previous(cpu: cpu, write: info.ri_diskio_byteswritten, energy: energy)
            next[pid] = current

            var sample = ProcessSample(pid: pid)
            sample.memory = Double(info.ri_phys_footprint)
            sample.cpuTime = Double(cpu) * MachTime.nsPerTick / 1e9
            if elapsed > 0, let before = previous[pid] {
                let cpuSeconds = Double(cpu &- before.cpu) * MachTime.nsPerTick / 1e9
                if cpu >= before.cpu { sample.cpu = cpuSeconds / elapsed / cores * 100 }
                if current.write >= before.write { sample.writeRate = Double(current.write - before.write) / elapsed }
                if energy >= before.energy { sample.watts = Double(energy - before.energy) / 1e9 / elapsed }
            }
            samples.append(sample)
        }
        previous = next
        return samples
    }
}

/// Groups processes under the app that is responsible for them (e.g. Chrome helpers → Google Chrome,
/// shells → Terminal), the same attribution Activity Monitor uses.
final class AppGrouper {
    struct Info {
        let key: String
        let name: String
        let iconPath: String?
        let executable: String
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private let responsible: ResponsibleFn?
    private var cache: [Int32: Info] = [:]
    private var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))

    init() {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
            responsible = unsafeBitCast(symbol, to: ResponsibleFn.self)
        } else {
            responsible = nil
        }
    }

    func info(for pid: Int32) -> Info {
        if let cached = cache[pid] { return cached }
        let executable = path(of: pid)
        var owner = responsible?(pid) ?? pid
        if owner <= 0 { owner = pid }
        let ownerPath = owner == pid ? executable : path(of: owner)
        let resolved = ownerPath.isEmpty ? executable : ownerPath

        let info: Info
        if let range = resolved.range(of: ".app/") ?? (resolved.hasSuffix(".app") ? resolved.range(of: ".app", options: .backwards) : nil) {
            let bundle = String(resolved[..<range.lowerBound]) + ".app"
            let name = FileManager.default.displayName(atPath: bundle).replacingOccurrences(of: ".app", with: "")
            info = Info(key: bundle, name: name, iconPath: bundle, executable: executable)
        } else if !resolved.isEmpty {
            info = Info(key: resolved, name: (resolved as NSString).lastPathComponent, iconPath: nil, executable: executable)
        } else {
            let name = processName(pid)
            info = Info(key: "name:" + name, name: name, iconPath: nil, executable: executable)
        }
        cache[pid] = info
        return info
    }

    func prune(keeping alive: Set<Int32>) {
        cache = cache.filter { alive.contains($0.key) }
    }

    private func path(of pid: Int32) -> String {
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return "" }
        return pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private func processName(_ pid: Int32) -> String {
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let result = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return result.isEmpty ? "pid \(pid)" : result
    }
}

struct AppUsage: Identifiable {
    let id: String
    let name: String
    let iconPath: String?
    var processes = 0
    var pids: [Int32] = []
    var cpu = 0.0
    var memory = 0.0
    var writeRate = 0.0
    var watts = 0.0
    var download = 0.0
    var gpu = 0.0
}
