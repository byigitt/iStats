import Darwin
import Foundation

struct Series {
    static let capacity = 90
    private(set) var values: [Float] = []

    mutating func append(_ value: Double) {
        if values.count >= Self.capacity { values.removeFirst(values.count - Self.capacity + 1) }
        values.append(Float(value.isFinite ? value : 0))
    }

    var average: Double { values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count) }
    var peak: Double { Double(values.max() ?? 0) }
}

struct Snapshot {
    var cpuUser = 0.0
    var cpuSystem = 0.0
    var cpuAverageToday = 0.0
    var load = 0.0
    var cpuHistory = Series()

    var memory = MemoryStats()
    var memoryHistory = Series()

    var disk = DiskStats()
    var diskHistory = Series()
    var writtenToday = 0.0

    var download = 0.0
    var upload = 0.0
    var networkHistory = Series()
    var networkToday = 0.0
    var networkWeek = 0.0
    var networkMonth = 0.0
    var interfaceName = "—"
    var interfaceBSD = ""

    var gpu = 0.0
    var gpuMemory = 0.0
    var gpuHistory = Series()

    var battery = BatteryStats()
    var batteryHistory = Series()

    var byCPU: [AppUsage] = []
    var byMemory: [AppUsage] = []
    var byDisk: [AppUsage] = []
    var byNetwork: [AppUsage] = []
    var byGPU: [AppUsage] = []
    var byPower: [AppUsage] = []
    var memoryAllApps = 0.0
    var powerAllApps = 0.0
    var appsReady = false

    var projects: [Project] = []
    var projectsReady = false

    var sensors = SensorReadings()
    var history: HistoryResult?
}

/// Per-day counters persisted in UserDefaults so "today" / "last 7 days" survive relaunches.
final class DailyStore {
    private let defaults = UserDefaults.standard
    private let storageKey = "daily.v1"
    private var days: [String: [String: Double]]
    private var recentKeys: [String] = []

    init() {
        days = defaults.dictionary(forKey: storageKey) as? [String: [String: Double]] ?? [:]
        roll()
    }

    private static func key(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func roll() {
        let today = Self.key(for: Date())
        guard recentKeys.first != today else { return }
        recentKeys = (0..<31).map { Self.key(for: Date(timeIntervalSinceNow: -Double($0) * 86400)) }
    }

    func add(_ key: String, _ value: Double) {
        guard value > 0 else { return }
        days[recentKeys[0], default: [:]][key, default: 0] += value
    }

    func today(_ key: String) -> Double { days[recentKeys[0]]?[key] ?? 0 }

    func sum(_ keys: [String], days count: Int) -> Double {
        var total = 0.0
        for day in recentKeys.prefix(count) {
            guard let values = days[day] else { continue }
            for key in keys { total += values[key] ?? 0 }
        }
        return total
    }

    func flush() {
        let keep = Set(recentKeys)
        days = days.filter { keep.contains($0.key) }
        defaults.set(days, forKey: storageKey)
    }
}

/// Owns every probe and samples them on a private queue. Heavy per-process work only runs while the
/// window is visible, and tab-specific work (GPU clients, nettop, projects) only for the visible tab.
final class Engine {
    let interval = 2.0
    private let queue = DispatchQueue(label: "istats.engine", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let cpu = CPUProbe()
    private let memory = MemoryProbe()
    private let disk = DiskProbe()
    private let network = NetworkProbe()
    let gpu = GPUProbe()
    private let battery = BatteryProbe()
    private let processes = ProcessProbe()
    private let grouper = AppGrouper()
    private let projects = ProjectsProbe()
    private lazy var netTop = NetTop(queue: queue)
    private lazy var sensors = SensorsProbe(queue: queue)
    private let daily = DailyStore()
    private let history = HistoryStore()
    private var historyRange = HistoryRange.live

    private var snapshot = Snapshot()
    private var tabs: Set<Tab> = []
    private let watch = AppWatch()
    private var pendingNetworkAlert: Double?
    private var ticks = 0
    private var lastProcesses: [ProcessSample] = []
    private var networkRates: [Int32: Double] = [:]

    private var previousDisk: (read: UInt64, write: UInt64) = (0, 0)
    private var previousNetwork: (rx: UInt64, tx: UInt64) = (0, 0)
    private var previousStamp = 0.0

    var onUpdate: ((Snapshot) -> Void)?
    var onAlert: ((AppAlert) -> Void)?

    var cpuCores: (total: Int, performance: Int, efficiency: Int) {
        (cpu.cores, cpu.performanceCores, cpu.efficiencyCores)
    }

    var memoryTotal: Double { memory.total }

    func start(showing tabs: Set<Tab>) {
        queue.async { [self] in
            self.tabs = tabs
            netTop.onSample = { [weak self] rates in self?.received(rates) }
            seedCounters()
            _ = cpu.sample()
            _ = processes.sample()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.4, repeating: interval, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            updateNetTop()
        }
    }

    /// Tabs currently on screen (main window and/or menu bar popover). Empty when nothing is visible.
    func update(showing tabs: Set<Tab>) {
        queue.async { [self] in
            let added = tabs.subtracting(self.tabs)
            self.tabs = tabs
            if added.contains(.gpu) { gpu.resetPerProcess(); _ = gpu.perProcess() }
            if !tabs.contains(.network) { networkRates = [:] }
            updateNetTop()
            if added.contains(.projects), !lastProcesses.isEmpty {
                snapshot.projects = projects.sample(processes: lastProcesses, grouper: grouper)
                snapshot.projectsReady = true
            }
            if !added.isEmpty {
                if !added.isDisjoint(with: [.cpu, .battery]) { sampleSensors() }
                publish()
            }
        }
    }

    /// `.live` stops history queries; any other range is refreshed once a minute while shown.
    func setHistoryRange(_ range: HistoryRange) {
        queue.async { [self] in
            historyRange = range
            snapshot.history = range == .live ? nil : history.query(range)
            publish()
        }
    }

    func terminate(pids: [Int32]) {
        queue.async { [self] in
            for pid in pids { kill(pid, SIGTERM) }
            queue.asyncAfter(deadline: .now() + 4) { [self] in
                for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                lastProcesses = processes.sample()
                snapshot.projects = projects.sample(processes: lastProcesses, grouper: grouper)
                publish()
            }
        }
    }

    func signal(_ pids: [Int32], force: Bool) {
        queue.async {
            for pid in pids where pid > 1 { kill(pid, force ? SIGKILL : SIGTERM) }
        }
    }

    func shutdown() {
        queue.sync {
            timer?.cancel()
            netTop.stop()
            persist()
            history.save()
        }
    }

    // MARK: - Sampling

    private func updateNetTop() {
        if tabs.contains(.network) || pendingNetworkAlert != nil { netTop.start() } else { netTop.stop() }
    }

    private func received(_ rates: [Int32: Double]) {
        guard let average = pendingNetworkAlert else {
            networkRates = rates
            return
        }
        pendingNetworkAlert = nil
        var totals: [String: (rate: Double, info: AppGrouper.Info)] = [:]
        for (pid, rate) in rates {
            let info = grouper.info(for: pid)
            totals[info.key, default: (0, info)].rate += rate
        }
        let top = totals.values.max { $0.rate < $1.rate }.map { AppUsage(id: $0.info.key, name: $0.info.name, iconPath: $0.info.iconPath) }
        let alert = watch.networkAlert(app: top, average: average)
        DispatchQueue.main.async { [weak self] in self?.onAlert?(alert) }
        if tabs.contains(.network) { networkRates = rates }
        updateNetTop()
    }

    private func sampleSensors() {
        snapshot.sensors = sensors.sample(includeAccessories: tabs.contains(.battery))
    }

    /// Credits traffic that happened while the app was closed (same boot session) to today.
    private func seedCounters() {
        let defaults = UserDefaults.standard
        let diskNow = disk.counters()
        let networkNow = network.counters()
        if defaults.double(forKey: "raw.boot") == Sysctl.bootTime {
            let written = UInt64(defaults.double(forKey: "raw.disk.write"))
            let rx = UInt64(defaults.double(forKey: "raw.net.rx"))
            let tx = UInt64(defaults.double(forKey: "raw.net.tx"))
            if diskNow.write >= written { daily.add("disk.write", Double(diskNow.write - written)) }
            if networkNow.rx >= rx { daily.add("net.rx", Double(networkNow.rx - rx)) }
            if networkNow.tx >= tx { daily.add("net.tx", Double(networkNow.tx - tx)) }
        }
        previousDisk = diskNow
        previousNetwork = networkNow
        previousStamp = MachTime.seconds
        refreshSlowStats()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(Sysctl.bootTime, forKey: "raw.boot")
        defaults.set(Double(previousDisk.write), forKey: "raw.disk.write")
        defaults.set(Double(previousNetwork.rx), forKey: "raw.net.rx")
        defaults.set(Double(previousNetwork.tx), forKey: "raw.net.tx")
        daily.flush()
    }

    private func refreshSlowStats() {
        let capacity = disk.capacity()
        snapshot.disk.total = capacity.total
        snapshot.disk.free = capacity.free
        snapshot.disk.volumes = disk.volumes()
        let interface = network.primaryInterface()
        snapshot.interfaceBSD = interface.bsd
        snapshot.interfaceName = interface.name
    }

    private func tick() {
        ticks += 1
        daily.roll()
        if ticks % 10 == 0 { refreshSlowStats() }

        let load = cpu.sample()
        snapshot.cpuUser = load.user
        snapshot.cpuSystem = load.system
        snapshot.load = cpu.load
        snapshot.cpuHistory.append(load.user + load.system)
        daily.add("cpu.sum", load.user + load.system)
        daily.add("cpu.count", 1)
        snapshot.cpuAverageToday = daily.today("cpu.sum") / max(daily.today("cpu.count"), 1)

        snapshot.memory = memory.sample()
        snapshot.memoryHistory.append(snapshot.memory.used)

        let now = MachTime.seconds
        let elapsed = max(now - previousStamp, 0.001)
        previousStamp = now

        let diskNow = disk.counters()
        let read = diskNow.read >= previousDisk.read ? Double(diskNow.read - previousDisk.read) : 0
        let written = diskNow.write >= previousDisk.write ? Double(diskNow.write - previousDisk.write) : 0
        previousDisk = diskNow
        snapshot.disk.readRate = read / elapsed
        snapshot.disk.writeRate = written / elapsed
        snapshot.diskHistory.append((read + written) / elapsed)
        daily.add("disk.write", written)
        snapshot.writtenToday = daily.today("disk.write")

        let networkNow = network.counters()
        let rx = networkNow.rx >= previousNetwork.rx ? Double(networkNow.rx - previousNetwork.rx) : 0
        let tx = networkNow.tx >= previousNetwork.tx ? Double(networkNow.tx - previousNetwork.tx) : 0
        previousNetwork = networkNow
        snapshot.download = rx / elapsed
        snapshot.upload = tx / elapsed
        snapshot.networkHistory.append(rx / elapsed)
        daily.add("net.rx", rx)
        daily.add("net.tx", tx)
        snapshot.networkToday = daily.sum(["net.rx", "net.tx"], days: 1)
        snapshot.networkWeek = daily.sum(["net.rx", "net.tx"], days: 7)
        snapshot.networkMonth = daily.sum(["net.rx", "net.tx"], days: 30)

        let graphics = gpu.sample()
        snapshot.gpu = graphics.utilization
        snapshot.gpuMemory = graphics.memory
        snapshot.gpuHistory.append(graphics.utilization)

        snapshot.battery = battery.sample()
        if snapshot.battery.present { snapshot.batteryHistory.append(snapshot.battery.percent) }

        // Per-process sampling always runs: the menu bar and busy-CPU alerts depend on it.
        let samples = processes.sample()
        lastProcesses = samples
        grouper.prune(keeping: Set(samples.map(\.pid)).union(networkRates.keys))
        let apps = aggregate(samples, gpu: tabs.contains(.gpu) ? gpu.perProcess() : [:])
        if tabs.contains(.projects) {
            snapshot.projects = projects.sample(processes: samples, grouper: grouper)
            snapshot.projectsReady = true
        }
        let watched = watch.feed(apps, download: snapshot.download, interval: interval, tick: ticks)
        if !watched.alerts.isEmpty {
            DispatchQueue.main.async { [weak self] in watched.alerts.forEach { self?.onAlert?($0) } }
        }
        if let average = watched.networkAverage, pendingNetworkAlert == nil {
            pendingNetworkAlert = average
            updateNetTop()
        }
        if !tabs.isDisjoint(with: [.cpu, .battery]) { sampleSensors() }

        history.record([
            snapshot.cpuUser + snapshot.cpuSystem,
            snapshot.memory.used,
            (read + written) / elapsed,
            (rx + tx) / elapsed,
            graphics.utilization,
            snapshot.battery.present ? snapshot.battery.percent : -1,
        ], apps: apps, interval: interval, cores: cpu.cores)
        if historyRange != .live, ticks % 30 == 0 { snapshot.history = history.query(historyRange) }

        if ticks % 30 == 0 {
            persist()
            malloc_zone_pressure_relief(nil, 0)
        }
        if ticks % 450 == 0 { history.save() }
        publish()
    }

    private func aggregate(_ samples: [ProcessSample], gpu perProcessGPU: [Int32: Double]) -> [AppUsage] {
        var groups: [String: AppUsage] = [:]
        func group(_ pid: Int32) -> String {
            let info = grouper.info(for: pid)
            if groups[info.key] == nil { groups[info.key] = AppUsage(id: info.key, name: info.name, iconPath: info.iconPath) }
            return info.key
        }
        for sample in samples {
            let key = group(sample.pid)
            groups[key]!.processes += 1
            groups[key]!.pids.append(sample.pid)
            groups[key]!.cpu += sample.cpu
            groups[key]!.memory += sample.memory
            groups[key]!.writeRate += sample.writeRate
            groups[key]!.watts += sample.watts
        }
        for (pid, rate) in networkRates {
            groups[group(pid)]!.download += rate
        }
        for (pid, busy) in perProcessGPU {
            let key = group(pid)
            groups[key]!.gpu = min(groups[key]!.gpu + busy, 100)
        }

        let apps = Array(groups.values)
        func top(_ metric: KeyPath<AppUsage, Double>) -> [AppUsage] {
            Array(apps.filter { $0[keyPath: metric] > 0 }.sorted { $0[keyPath: metric] > $1[keyPath: metric] }.prefix(8))
        }
        snapshot.byCPU = top(\.cpu)
        snapshot.byMemory = top(\.memory)
        snapshot.byDisk = top(\.writeRate)
        snapshot.byNetwork = top(\.download)
        snapshot.byGPU = top(\.gpu)
        snapshot.byPower = top(\.watts)
        snapshot.memoryAllApps = apps.reduce(0) { $0 + $1.memory }
        snapshot.powerAllApps = apps.reduce(0) { $0 + $1.watts }
        snapshot.appsReady = true
        return apps
    }

    private func publish() {
        let copy = snapshot
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(copy) }
    }
}
