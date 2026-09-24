import Foundation

enum HistoryRange: String, CaseIterable, Identifiable {
    case live = "Live", hours12 = "12h", hours24 = "24h", days7 = "7d", days30 = "30d"

    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .live: 0
        case .hours12: 12 * 3600
        case .hours24: 24 * 3600
        case .days7: 7 * 86400
        case .days30: 30 * 86400
        }
    }
    var bars: Int {
        switch self {
        case .live: 0
        case .hours12, .hours24: 24
        case .days7: 28
        case .days30: 30
        }
    }
    var label: String {
        switch self {
        case .live: "Live"
        case .hours12: "last 12 hours"
        case .hours24: "last 24 hours"
        case .days7: "last 7 days"
        case .days30: "last 30 days"
        }
    }
}

enum HistoryMetric: Int, CaseIterable {
    case cpu, memory, disk, network, gpu, battery
}

struct HistoryApp: Identifiable {
    let id: String
    let name: String
    let iconPath: String?
    /// CPU seconds (all cores) spent during the range.
    var cpuSeconds = 0.0
    /// Average footprint over the hours the app was running.
    var memory = 0.0
}

struct HistoryResult {
    let range: HistoryRange
    /// Per metric, one value per bar; negative where nothing was recorded.
    var bars: [[Float]]
    var averages: [Double]
    var peaks: [Double]
    var topCPU: [HistoryApp]
    var topMemory: [HistoryApp]

    func bars(_ metric: HistoryMetric) -> [Float] { bars[metric.rawValue] }
    func average(_ metric: HistoryMetric) -> Double { averages[metric.rawValue] }
    func peak(_ metric: HistoryMetric) -> Double { peaks[metric.rawValue] }
}

/// Thirty days of five-minute averages plus the busiest apps of every hour, kept in one small
/// binary property list in Application Support.
final class HistoryStore {
    private static let bucketLength = 300.0
    private static let retention = 30 * 86400.0

    private struct Bucket {
        var start: UInt32
        var values: (Float, Float, Float, Float, Float, Float)

        subscript(metric: Int) -> Float {
            switch metric {
            case 0: values.0
            case 1: values.1
            case 2: values.2
            case 3: values.3
            case 4: values.4
            default: values.5
            }
        }
    }

    private struct HourEntry: Codable {
        var app: Int
        var cpu: Float
        var memory: Float
    }

    private struct Hour: Codable {
        var start: UInt32
        var entries: [HourEntry]
    }

    private struct AppName: Codable {
        var key: String
        var name: String
        var icon: String?
    }

    private struct Archive: Codable {
        var buckets: Data
        var hours: [Hour]
        var apps: [AppName]
    }

    private struct Accumulator {
        var name: String
        var iconPath: String?
        var cpu = 0.0
        var memory = 0.0
    }

    private let url: URL
    private var buckets: [Bucket] = []
    private var hours: [Hour] = []
    private var apps: [AppName] = []
    private var appIndex: [String: Int] = [:]

    private var bucketStart = 0.0
    private var sums = [Double](repeating: 0, count: HistoryMetric.allCases.count)
    private var counts = [Int](repeating: 0, count: HistoryMetric.allCases.count)
    private var hourStart = 0.0
    private var hourTicks = 0
    private var hourApps: [String: Accumulator] = [:]
    private var dirty = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iStats", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("history.plist")
        load()
    }

    /// `values` is indexed by `HistoryMetric`; negative values are skipped (e.g. no battery).
    func record(_ values: [Double], apps usage: [AppUsage], interval: Double, cores: Int) {
        let now = Date().timeIntervalSince1970
        let bucket = (now / Self.bucketLength).rounded(.down) * Self.bucketLength
        if bucket != bucketStart {
            closeBucket()
            bucketStart = bucket
        }
        for (index, value) in values.enumerated() where value >= 0 && value.isFinite {
            sums[index] += value
            counts[index] += 1
        }

        let hour = (now / 3600).rounded(.down) * 3600
        if hour != hourStart {
            closeHour()
            hourStart = hour
        }
        hourTicks += 1
        let coreSeconds = Double(cores) * interval / 100
        for app in usage {
            hourApps[app.id, default: Accumulator(name: app.name, iconPath: app.iconPath)].cpu += app.cpu * coreSeconds
            hourApps[app.id]!.memory += app.memory
        }
    }

    func query(_ range: HistoryRange) -> HistoryResult {
        let now = Date().timeIntervalSince1970
        let start = now - range.seconds
        let slot = range.seconds / Double(range.bars)
        let metrics = HistoryMetric.allCases.count
        var sums = [[Double]](repeating: [Double](repeating: 0, count: range.bars), count: metrics)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: range.bars), count: metrics)
        var totals = [Double](repeating: 0, count: metrics)
        var totalCounts = [Int](repeating: 0, count: metrics)
        var peaks = [Double](repeating: 0, count: metrics)

        func add(_ time: Double, _ value: (Int) -> Float?) {
            guard time >= start else { return }
            let index = min(Int((time - start) / slot), range.bars - 1)
            for metric in 0..<metrics {
                guard let v = value(metric), v >= 0 else { continue }
                sums[metric][index] += Double(v)
                counts[metric][index] += 1
                totals[metric] += Double(v)
                totalCounts[metric] += 1
                peaks[metric] = max(peaks[metric], Double(v))
            }
        }
        let first = buckets.firstIndex { Double($0.start) >= start } ?? buckets.endIndex
        for bucket in buckets[first...] where bucket.start != UInt32(bucketStart) {
            add(Double(bucket.start)) { bucket[$0] }
        }
        if bucketStart > 0 {
            add(bucketStart) { self.counts[$0] > 0 ? Float(self.sums[$0] / Double(self.counts[$0])) : nil }
        }

        let bars = (0..<metrics).map { metric in
            (0..<range.bars).map { counts[metric][$0] > 0 ? Float(sums[metric][$0] / Double(counts[metric][$0])) : -1 }
        }
        let averages = (0..<metrics).map { totalCounts[$0] > 0 ? totals[$0] / Double(totalCounts[$0]) : 0 }

        var usage: [String: (app: HistoryApp, hours: Int)] = [:]
        func credit(_ key: String, name: String, icon: String?, cpu: Double, memory: Double) {
            var entry = usage[key] ?? (HistoryApp(id: key, name: name, iconPath: icon), 0)
            entry.app.cpuSeconds += cpu
            entry.app.memory += memory
            entry.hours += 1
            usage[key] = entry
        }
        for hour in hours where Double(hour.start) >= start - 3600 {
            for entry in hour.entries where entry.app < apps.count {
                let app = apps[entry.app]
                credit(app.key, name: app.name, icon: app.icon, cpu: Double(entry.cpu), memory: Double(entry.memory))
            }
        }
        if hourTicks > 0 {
            for (key, value) in hourApps {
                credit(key, name: value.name, icon: value.iconPath, cpu: value.cpu, memory: value.memory / Double(hourTicks))
            }
        }
        let all = usage.values.map { entry -> HistoryApp in
            var app = entry.app
            app.memory /= Double(max(entry.hours, 1))
            return app
        }
        let topCPU = all.filter { $0.cpuSeconds > 0 }.sorted { $0.cpuSeconds > $1.cpuSeconds }.prefix(8)
        let topMemory = all.filter { $0.memory > 0 }.sorted { $0.memory > $1.memory }.prefix(8)
        return HistoryResult(
            range: range, bars: bars, averages: averages, peaks: peaks,
            topCPU: Array(topCPU), topMemory: Array(topMemory))
    }

    func save() {
        closeBucket(keepOpen: true)
        guard dirty else { return }
        let raw = buckets.withUnsafeBytes { Data($0) }
        let archive = Archive(buckets: raw, hours: hours, apps: apps)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(archive) else { return }
        try? data.write(to: url, options: .atomic)
        dirty = false
    }

    // MARK: - Private

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let archive = try? PropertyListDecoder().decode(Archive.self, from: data),
              archive.buckets.count % MemoryLayout<Bucket>.stride == 0
        else { return }
        buckets = archive.buckets.withUnsafeBytes { Array($0.bindMemory(to: Bucket.self)) }
        hours = archive.hours
        apps = archive.apps
        for (index, app) in apps.enumerated() { appIndex[app.key] = index }
        prune()
    }

    /// With `keepOpen`, the current partial bucket is written but keeps accumulating.
    private func closeBucket(keepOpen: Bool = false) {
        guard bucketStart > 0, counts.contains(where: { $0 > 0 }) else { return }
        func average(_ index: Int) -> Float { counts[index] > 0 ? Float(sums[index] / Double(counts[index])) : -1 }
        let bucket = Bucket(start: UInt32(bucketStart), values: (average(0), average(1), average(2), average(3), average(4), average(5)))
        if buckets.last?.start == bucket.start { buckets[buckets.count - 1] = bucket } else { buckets.append(bucket) }
        dirty = true
        guard !keepOpen else { return }
        sums = sums.map { _ in 0 }
        counts = counts.map { _ in 0 }
        prune()
    }

    private func closeHour() {
        guard hourStart > 0, hourTicks > 0 else { return }
        let averaged = hourApps.map { (key: $0.key, value: $0.value, memory: $0.value.memory / Double(hourTicks)) }
        let byCPU = averaged.filter { $0.value.cpu > 0 }.sorted { $0.value.cpu > $1.value.cpu }.prefix(6)
        let byMemory = averaged.sorted { $0.memory > $1.memory }.prefix(6)
        var seen = Set<String>()
        var entries: [HourEntry] = []
        for item in Array(byCPU) + Array(byMemory) where seen.insert(item.key).inserted {
            entries.append(HourEntry(app: index(for: item.key, name: item.value.name, icon: item.value.iconPath),
                                     cpu: Float(item.value.cpu), memory: Float(item.memory)))
        }
        hours.append(Hour(start: UInt32(hourStart), entries: entries))
        hourApps.removeAll(keepingCapacity: true)
        hourTicks = 0
        dirty = true
    }

    private func index(for key: String, name: String, icon: String?) -> Int {
        if let index = appIndex[key] { return index }
        apps.append(AppName(key: key, name: name, icon: icon))
        appIndex[key] = apps.count - 1
        return apps.count - 1
    }

    private func prune() {
        let cutoff = UInt32(max(Date().timeIntervalSince1970 - Self.retention, 0))
        if let first = buckets.firstIndex(where: { $0.start >= cutoff }), first > 0 { buckets.removeFirst(first) }
        if let first = hours.firstIndex(where: { $0.start >= cutoff }), first > 0 {
            hours.removeFirst(first)
            let used = Set(hours.flatMap { $0.entries.map(\.app) })
            guard used.count < apps.count else { return }
            // Compact the name table so apps that fell out of the window don't accumulate forever.
            var remap: [Int: Int] = [:]
            var kept: [AppName] = []
            for (index, app) in apps.enumerated() where used.contains(index) {
                remap[index] = kept.count
                kept.append(app)
            }
            apps = kept
            appIndex = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1.key, $0) })
            hours = hours.map { hour in
                Hour(start: hour.start, entries: hour.entries.compactMap { entry in
                    remap[entry.app].map { HourEntry(app: $0, cpu: entry.cpu, memory: entry.memory) }
                })
            }
        }
    }
}
