import AppKit
import SwiftUI

struct Hero {
    let caption: String
    let value: (String, String)
    var pressure: Int?
    let rows: [Stat]
    let series: Series
    let maximum: Double?
    var history: HistoryMetric?
    var historyFormat: (Double) -> String = Format.percent
}

enum StatDetail {
    case none
    case text(String)
    case progress(Double)
    case chips([String])
}

struct StatItem: Identifiable {
    let icon: String
    let title: String
    let value: String
    var detail: StatDetail = .none
    var id: String { title }
}

/// Shared layout for the CPU / Memory / Disk / Network / GPU / Battery tabs.
struct DetailScreen<Extra: View>: View {
    @Environment(Monitor.self) private var monitor
    let tab: Tab
    let hero: Hero
    let stats: [StatItem]
    let listTitle: String
    let apps: [AppUsage]
    let metric: KeyPath<AppUsage, Double>
    let format: (Double) -> String
    let ready: Bool
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 14) {
            HeroCard(tab: tab, hero: hero)
            HStack(spacing: 14) {
                ForEach(stats) { StatCard(item: $0, color: tab.color) }
                TopAppCard(app: apps.first, value: apps.first.map { format($0[keyPath: metric]) }, color: tab.color)
            }
            .fixedSize(horizontal: false, vertical: true)
            extra
            if let history = monitor.snapshot.history, monitor.historyRange != .live, tab == .cpu || tab == .memory {
                historyList(history)
            } else {
                AppList(title: listTitle, apps: apps, metric: metric, format: format, color: tab.color, ready: ready)
            }
        }
    }

    /// Apps that used the most over the selected range, from the hourly history.
    private func historyList(_ history: HistoryResult) -> some View {
        let cpu = tab == .cpu
        let source = cpu ? history.topCPU : history.topMemory
        let apps = source.map { AppUsage(id: $0.id, name: $0.name, iconPath: $0.iconPath, cpu: $0.cpuSeconds, memory: $0.memory) }
        return AppList(
            title: cpu ? "CPU time, \(history.range.label)" : "Average memory, \(history.range.label)",
            apps: apps, metric: cpu ? \.cpu : \.memory, format: cpu ? Format.cpuTime : Format.memory,
            color: tab.color, ready: true, subtitle: { _ in cpu ? "Total across all cores" : "While running" })
    }
}

extension DetailScreen where Extra == EmptyView {
    init(tab: Tab, hero: Hero, stats: [StatItem], listTitle: String, apps: [AppUsage],
         metric: KeyPath<AppUsage, Double>, format: @escaping (Double) -> String, ready: Bool) {
        self.init(tab: tab, hero: hero, stats: stats, listTitle: listTitle, apps: apps,
                  metric: metric, format: format, ready: ready) { EmptyView() }
    }
}

struct HeroCard: View {
    @Environment(Monitor.self) private var monitor
    let tab: Tab
    let hero: Hero

    var body: some View {
        @Bindable var monitor = monitor
        let history = hero.history != nil && monitor.historyRange != .live ? monitor.snapshot.history : nil
        let rows = if let history, let metric = hero.history {
            [Stat(label: "Average", value: hero.historyFormat(history.average(metric))),
             Stat(label: "Peak", value: hero.historyFormat(history.peak(metric)))]
        } else {
            hero.rows
        }
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                Text(hero.caption).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                HeroValue(parts: hero.value, size: 44)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 2)
                if let pressure = hero.pressure { PressureBadge(level: pressure).padding(.top, 4) }
                Spacer(minLength: 10)
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        HStack {
                            Text(row.label).foregroundStyle(Palette.secondary)
                            Spacer()
                            Text(row.value).fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .lineLimit(1)
                    }
                }
            }
            .frame(width: 190)
            VStack(alignment: .trailing, spacing: 8) {
                if hero.history != nil {
                    RangePicker(selection: $monitor.historyRange, color: tab.color)
                }
                if let history, let metric = hero.history {
                    HistoryBars(values: history.bars(metric), maximum: hero.maximum, color: tab.color)
                    HStack {
                        Text(history.range.label.capitalized)
                        Spacer()
                        Text("Now")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.tertiary)
                } else {
                    AreaChart(values: hero.series.values, maximum: hero.maximum, color: tab.color)
                }
            }
        }
        .frame(height: 148)
        .padding(18)
        .cardBackground()
    }
}

struct StatCard: View {
    let item: StatItem
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconBadge(symbol: item.icon, color: color, size: 22)
                Text(item.title).font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
            }
            Text(item.value)
                .font(.system(size: 21, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 13)
            Group {
                switch item.detail {
                case .none: EmptyView()
                case .text(let text): Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(1)
                case .progress(let fraction): ProgressBar(fraction: fraction, color: color, height: 5)
                case .chips(let chips): HStack(spacing: 5) { ForEach(chips, id: \.self) { Chip(text: $0, color: color) } }
                }
            }
            .padding(.top, 7)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

struct TopAppCard: View {
    let app: AppUsage?
    let value: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconBadge(symbol: "square.grid.2x2", color: color, size: 22)
                Text("Top App").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 8) {
                if let app { AppIcon(path: app.iconPath, size: 20) }
                Text(app?.name ?? "—").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .frame(height: 25)
            .padding(.top, 13)
            HStack {
                Text(value ?? " ").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Spacer()
                if app?.iconPath != nil {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.tertiary)
                }
            }
            .padding(.top, 7)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
        .contentShape(Rectangle())
        .onTapGesture { app.flatMap(\.iconPath).map(openApp) }
        .modifier(OptionalAppActions(app: app))
    }
}

private struct OptionalAppActions: ViewModifier {
    let app: AppUsage?

    func body(content: Content) -> some View {
        if let app { content.appActions(app) } else { content }
    }
}

func openApp(_ path: String) {
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
}

struct AppList: View {
    let title: String
    let apps: [AppUsage]
    let metric: KeyPath<AppUsage, Double>
    let format: (Double) -> String
    let color: Color
    let ready: Bool
    var subtitle: ((AppUsage) -> String)?

    var body: some View {
        let peak: Double = apps.first.map { $0[keyPath: metric] } ?? 1
        VStack(spacing: 2) {
            HStack {
                Text("App")
                Spacer()
                Text(title)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)

            if apps.isEmpty {
                Text(ready ? "No activity right now" : "Collecting…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                AppRow(app: app, value: format(app[keyPath: metric]), fraction: app[keyPath: metric] / max(peak, 1e-9),
                       color: color, highlighted: index == 0, subtitle: subtitle?(app))
            }
        }
        .padding(8)
        .cardBackground()
    }
}

struct AppRow: View {
    let app: AppUsage
    let value: String
    let fraction: Double
    let color: Color
    let highlighted: Bool
    var subtitle: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(path: app.iconPath, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(subtitle ?? (app.processes == 1 ? "1 process" : "\(app.processes) processes"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                ProgressBar(fraction: fraction, color: color).frame(width: 155)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(highlighted || hovering ? 0.045 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .appActions(app)
    }
}

// MARK: - Tabs

struct CPUView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let chips = monitor.efficiencyCores > 0
            ? ["\(monitor.performanceCores) P", "\(monitor.efficiencyCores) E"]
            : ["\(monitor.cores) threads"]
        DetailScreen(
            tab: .cpu,
            hero: Hero(
                caption: "Now", value: (String(Int((s.cpuUser + s.cpuSystem).rounded())), "%"),
                rows: [
                    Stat(label: "Average today", value: Format.percent(s.cpuAverageToday)),
                    Stat(label: "Load", value: String(format: "%.2f", s.load)),
                ] + (s.sensors.cpuTemperature.map { [Stat(label: "Temperature", value: Format.temperature($0))] } ?? []),
                series: s.cpuHistory, maximum: 100, history: .cpu
            ),
            stats: [
                StatItem(icon: "person.fill", title: "User", value: Format.percent(s.cpuUser), detail: .text("Your apps")),
                StatItem(icon: "gearshape.fill", title: "System", value: Format.percent(s.cpuSystem), detail: .text("macOS")),
                StatItem(icon: "bolt.fill", title: "Cores", value: "\(monitor.cores)", detail: .chips(chips)),
            ],
            listTitle: "CPU", apps: s.byCPU, metric: \.cpu, format: { String(format: "%.1f%%", $0) }, ready: s.appsReady
        )
    }
}

struct MemoryView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let total = max(s.memory.total, 1)
        DetailScreen(
            tab: .memory,
            hero: Hero(
                caption: "In use of \(Int((monitor.memoryTotal / 1_073_741_824).rounded())) GB",
                value: Format.memoryParts(s.memory.used), pressure: s.memory.pressure,
                rows: [
                    Stat(label: "Free", value: Format.memory(s.memory.available)),
                    Stat(label: "Swap", value: Format.memory(s.memory.swap)),
                ],
                series: s.memoryHistory, maximum: monitor.memoryTotal, history: .memory, historyFormat: Format.memory
            ),
            stats: [
                StatItem(icon: "square.grid.2x2", title: "App", value: Format.memory(s.memory.app), detail: .progress(s.memory.app / total)),
                StatItem(icon: "lock.fill", title: "Wired", value: Format.memory(s.memory.wired), detail: .progress(s.memory.wired / total)),
                StatItem(icon: "memorychip", title: "Compressed", value: Format.memory(s.memory.compressed), detail: .progress(s.memory.compressed / total)),
            ],
            listTitle: "Memory", apps: s.byMemory, metric: \.memory, format: Format.memory, ready: s.appsReady
        )
    }
}

struct DiskView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        DetailScreen(
            tab: .disk,
            hero: Hero(
                caption: "Free of \(Format.storage(s.disk.total))", value: Format.storageParts(s.disk.free),
                rows: [
                    Stat(label: "Used", value: Format.storage(s.disk.used)),
                    Stat(label: "Written today", value: Format.total(s.writtenToday)),
                ],
                series: s.diskHistory, maximum: nil, history: .disk, historyFormat: Format.rate
            ),
            stats: [
                StatItem(icon: "arrow.down", title: "Reading", value: Format.rate(s.disk.readRate)),
                StatItem(icon: "arrow.up", title: "Writing", value: Format.rate(s.disk.writeRate)),
                StatItem(icon: "internaldrive", title: "Volumes", value: "\(s.disk.volumes.count)", detail: .chips(Array(s.disk.volumes.prefix(2)))),
            ],
            listTitle: "Writing", apps: s.byDisk, metric: \.writeRate, format: Format.rate, ready: s.appsReady
        )
    }
}

struct NetworkView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        DetailScreen(
            tab: .network,
            hero: Hero(
                caption: "Downloading", value: Format.rateParts(s.download),
                rows: [
                    Stat(label: "Today", value: Format.total(s.networkToday)),
                    Stat(label: "Last 30 days", value: Format.total(s.networkMonth)),
                ],
                series: s.networkHistory, maximum: nil, history: .network, historyFormat: Format.rate
            ),
            stats: [
                StatItem(icon: "arrow.up", title: "Uploading", value: Format.rate(s.upload)),
                StatItem(icon: "chart.bar.fill", title: "Last 7 Days", value: Format.total(s.networkWeek)),
                StatItem(icon: s.interfaceName == "Wi-Fi" ? "wifi" : "network", title: "Interface", value: s.interfaceName,
                         detail: .text(s.interfaceBSD)),
            ],
            listTitle: "Downloading", apps: s.byNetwork, metric: \.download, format: Format.rate, ready: s.appsReady
        )
    }
}

struct GPUView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        DetailScreen(
            tab: .gpu,
            hero: Hero(
                caption: monitor.gpuName, value: (String(Int(s.gpu.rounded())), "%"),
                rows: [
                    Stat(label: "Average", value: Format.percent(s.gpuHistory.average)),
                    Stat(label: "Peak", value: Format.percent(s.gpuHistory.peak)),
                ],
                series: s.gpuHistory, maximum: 100, history: .gpu
            ),
            stats: [
                StatItem(icon: "memorychip", title: "Memory", value: Format.memory(s.gpuMemory)),
                StatItem(icon: "chart.bar.fill", title: "Average", value: Format.percent(s.gpuHistory.average)),
                StatItem(icon: "bolt.fill", title: "Peak", value: Format.percent(s.gpuHistory.peak)),
            ],
            listTitle: "GPU", apps: s.byGPU, metric: \.gpu, format: Format.percentFine, ready: s.appsReady
        )
    }
}

struct BatteryView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let battery = s.battery
        if !battery.present {
            VStack(spacing: 14) {
                Card {
                    VStack(spacing: 10) {
                        IconBadge(symbol: "powerplug.fill", color: Palette.green, size: 40)
                        Text("This Mac has no battery").font(.system(size: 15, weight: .semibold))
                        Text("Per-app power is still measured below.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
                .fixedSize(horizontal: false, vertical: true)
                SensorsCard(sensors: s.sensors)
                AppList(title: "Power", apps: s.byPower, metric: \.watts, format: Format.watts, color: Palette.green, ready: s.appsReady)
            }
        } else {
            let remaining: String = if let seconds = battery.remaining {
                Format.duration(seconds)
            } else if let seconds = battery.toFull {
                Format.duration(seconds)
            } else {
                battery.external ? (battery.percent >= 99 ? "Full" : "—") : "Calculating"
            }
            DetailScreen(
                tab: .battery,
                hero: Hero(
                    caption: battery.statusText, value: (String(Int(battery.percent.rounded())), "%"),
                    rows: [
                        Stat(label: battery.toFull != nil ? "Until full" : "Remaining", value: remaining),
                        Stat(label: "Cycles", value: "\(battery.cycles)"),
                    ],
                    series: s.batteryHistory, maximum: 100, history: .battery
                ),
                stats: [
                    StatItem(icon: "bolt.fill", title: battery.charging ? "Charge Rate" : "Power Draw", value: Format.watts(battery.watts)),
                    StatItem(icon: "heart.fill", title: "Health", value: Format.percent(battery.health), detail: .progress(battery.health / 100)),
                    StatItem(icon: "thermometer.medium", title: "Temperature", value: String(format: "%.0f°", battery.temperature)),
                ],
                listTitle: "Power", apps: s.byPower, metric: \.watts, format: Format.watts, ready: s.appsReady
            ) {
                SensorsCard(sensors: s.sensors)
            }
        }
    }
}

/// SoC temperature, fan speeds and Bluetooth accessory batteries.
struct SensorsCard: View {
    let sensors: SensorReadings

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
        VStack(alignment: .leading, spacing: 10) {
            Text("Temperatures, Fans & Accessories")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4)
            LazyVGrid(columns: columns, spacing: 10) {
                if let temperature = sensors.cpuTemperature {
                    tile("thermometer.medium", Palette.red, "CPU", Format.temperature(temperature), fraction: temperature / 110)
                }
                ForEach(Array(sensors.fans.enumerated()), id: \.offset) { index, rpm in
                    tile("fan.fill", Palette.teal, sensors.fans.count > 1 ? "Fan \(index + 1)" : "Fan",
                         rpm < 1 ? "Off" : "\(Int(rpm)) rpm", fraction: nil)
                }
                ForEach(sensors.accessories) { device in
                    tile(device.symbol, device.percent <= 20 ? Palette.red : Palette.green, device.name, "\(device.percent)%",
                         fraction: Double(device.percent) / 100)
                }
            }
            if sensors.cpuTemperature == nil, sensors.fans.isEmpty, sensors.accessories.isEmpty {
                Text("Reading sensors…").font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.horizontal, 4)
            }
        }
        .padding(14)
        .cardBackground()
    }

    private func tile(_ symbol: String, _ color: Color, _ title: String, _ value: String, fraction: Double?) -> some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(1)
                Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1)
                if let fraction { ProgressBar(fraction: fraction, color: color, height: 4) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}
