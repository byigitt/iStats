import SwiftUI

struct Stat: Identifiable {
    let label: String
    let value: String
    var dot: Color?
    var id: String { label }
}

struct OverviewView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                MetricCard(
                    tab: .cpu, caption: "Now", value: (String(Int((s.cpuUser + s.cpuSystem).rounded())), "%"),
                    stats: [
                        Stat(label: "User", value: Format.percent(s.cpuUser)),
                        Stat(label: "System", value: Format.percent(s.cpuSystem)),
                        Stat(label: "Average Today", value: Format.percent(s.cpuAverageToday)),
                    ],
                    series: s.cpuHistory, maximum: 100
                )
                MetricCard(
                    tab: .memory, caption: "In Use of \(Int((monitor.memoryTotal / 1_073_741_824).rounded())) GB",
                    value: Format.memoryParts(s.memory.used), badge: s.memory.total > 0 ? s.memory.pressure : nil,
                    stats: [
                        Stat(label: "App", value: Format.memory(s.memory.app), dot: MemoryColors.app),
                        Stat(label: "Wired", value: Format.memory(s.memory.wired), dot: MemoryColors.wired),
                        Stat(label: "Compressed", value: Format.memory(s.memory.compressed), dot: MemoryColors.compressed),
                    ],
                    series: s.memoryHistory, maximum: monitor.memoryTotal
                )
                MetricCard(
                    tab: .gpu, caption: monitor.gpuName, value: (String(Int(s.gpu.rounded())), "%"),
                    stats: [
                        Stat(label: "Memory", value: Format.memory(s.gpuMemory)),
                        Stat(label: "Average", value: Format.percent(s.gpuHistory.average)),
                        Stat(label: "Peak", value: Format.percent(s.gpuHistory.peak)),
                    ],
                    series: s.gpuHistory, maximum: 100
                )
            }
            GridRow {
                MetricCard(
                    tab: .disk, caption: "Free of \(Format.storage(s.disk.total))", value: Format.storageParts(s.disk.free),
                    stats: [
                        Stat(label: "Reading", value: Format.rate(s.disk.readRate)),
                        Stat(label: "Writing", value: Format.rate(s.disk.writeRate)),
                        Stat(label: "Written Today", value: Format.total(s.writtenToday)),
                    ],
                    series: s.diskHistory, maximum: nil
                )
                MetricCard(
                    tab: .network, caption: "Downloading", value: Format.rateParts(s.download),
                    stats: [
                        Stat(label: "Uploading", value: Format.rate(s.upload)),
                        Stat(label: "Today", value: Format.total(s.networkToday)),
                        Stat(label: "Last 7 Days", value: Format.total(s.networkWeek)),
                    ],
                    series: s.networkHistory, maximum: nil
                )
                batteryCard(s.battery, history: s.batteryHistory)
            }
            GridRow {
                memoryTypeCard(s.memory)
                BreakdownCard(
                    title: "Memory by App", icon: "square.grid.2x2", color: Palette.purple,
                    center: Format.memory(s.memoryAllApps), subtitle: "all apps",
                    items: breakdown(s.byMemory, total: s.memoryAllApps, metric: \.memory, shades: MemoryColors.apps, format: Format.memory),
                    ready: s.appsReady
                )
                BreakdownCard(
                    title: "Power by App", icon: "bolt.fill", color: Palette.green,
                    center: Format.watts(s.powerAllApps), subtitle: "all apps",
                    items: breakdown(s.byPower, total: s.powerAllApps, metric: \.watts, shades: MemoryColors.power, format: Format.watts),
                    ready: s.appsReady
                )
            }
        }
    }

    private func batteryCard(_ battery: BatteryStats, history: Series) -> some View {
        let remaining: String = if let seconds = battery.remaining {
            Format.duration(seconds)
        } else if let seconds = battery.toFull {
            Format.duration(seconds)
        } else {
            battery.external ? (battery.percent >= 99 ? "Full" : "—") : "Calculating"
        }
        return MetricCard(
            tab: .battery, caption: battery.statusText,
            value: battery.present ? (String(Int(battery.percent.rounded())), "%") : ("—", ""),
            stats: [
                Stat(label: battery.toFull != nil ? "Until Full" : "Remaining", value: battery.present ? remaining : "—"),
                Stat(label: battery.charging ? "Charge Rate" : "Power Draw", value: battery.present ? Format.watts(battery.watts) : "—"),
                Stat(label: "Health", value: battery.present ? Format.percent(battery.health) : "—"),
            ],
            series: history, maximum: 100
        )
    }

    private func memoryTypeCard(_ memory: MemoryStats) -> some View {
        let used = memory.total > 0 ? memory.used / memory.total * 100 : 0
        let items = [
            BreakdownItem(name: "App", amount: memory.app, value: Format.memory(memory.app), color: MemoryColors.app),
            BreakdownItem(name: "Wired", amount: memory.wired, value: Format.memory(memory.wired), color: MemoryColors.wired),
            BreakdownItem(name: "Compressed", amount: memory.compressed, value: Format.memory(memory.compressed), color: MemoryColors.compressed),
            BreakdownItem(name: "Cached", amount: memory.cached, value: Format.memory(memory.cached), color: MemoryColors.cached),
            BreakdownItem(name: "Free", amount: memory.free, value: Format.memory(memory.free), color: MemoryColors.free),
        ]
        return BreakdownCard(
            title: "Memory by Type", icon: "memorychip", color: Palette.blue,
            center: Format.percent(used), subtitle: "in use", items: items, ready: memory.total > 0
        )
    }

    private func breakdown(
        _ apps: [AppUsage], total: Double, metric: KeyPath<AppUsage, Double>, shades: [Color], format: (Double) -> String
    ) -> [BreakdownItem] {
        var items = apps.prefix(4).enumerated().map { index, app in
            BreakdownItem(name: app.name, amount: app[keyPath: metric], value: format(app[keyPath: metric]),
                          color: shades[index % shades.count], iconPath: app.iconPath ?? "", key: app.id)
        }
        let rest = max(total - items.reduce(0) { $0 + $1.amount }, 0)
        items.append(BreakdownItem(name: "Other", amount: rest, value: format(rest), color: MemoryColors.cached.opacity(0.6)))
        return items
    }
}

enum MemoryColors {
    static let app = Palette.blue
    static let wired = Palette.orange
    static let compressed = Palette.teal
    static let cached = Palette.gray
    static let free = Color.primary.opacity(0.14)
    static let apps = [Color(hex: 0x9D8CF7), Color(hex: 0x8171E6), Color(hex: 0x6B5BCF), Color(hex: 0x5747B3)]
    static let power = [Color(hex: 0x3AC34C), Color(hex: 0x2EA63F), Color(hex: 0x248A33), Color(hex: 0x1B6E28)]
}

struct MetricCard: View {
    @Environment(Monitor.self) private var monitor
    let tab: Tab
    let caption: String
    let value: (String, String)
    var badge: Int?
    let stats: [Stat]
    let series: Series
    let maximum: Double?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: tab.title, icon: tab.icon, color: tab.color, showsChevron: true)
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .padding(.top, 14)
                HStack(alignment: .center) {
                    HeroValue(parts: value)
                    Spacer(minLength: 4)
                    if let badge { PressureBadge(level: badge) }
                }
                .padding(.top, 1)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(stats) { stat in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                if let dot = stat.dot { Circle().fill(dot).frame(width: 6, height: 6) }
                                Text(stat.label).font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                            }
                            Text(stat.value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 12)
                SparkBars(values: series.values, maximum: maximum, color: tab.color)
                    .frame(height: 38)
                    .padding(.top, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { monitor.tab = tab }
    }
}

struct CardHeader: View {
    let title: String
    let icon: String
    let color: Color
    var showsChevron = false

    var body: some View {
        HStack(spacing: 9) {
            IconBadge(symbol: icon, color: color)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }
}

struct BreakdownItem: Identifiable {
    let name: String
    let amount: Double
    let value: String
    let color: Color
    var iconPath: String?
    var key: String?

    var id: String { key ?? name }
}

struct BreakdownCard: View {
    let title: String
    let icon: String
    let color: Color
    let center: String
    let subtitle: String
    let items: [BreakdownItem]
    let ready: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: title, icon: icon, color: color)
                HStack(spacing: 18) {
                    Donut(segments: ready ? items.map { ($0.amount, $0.color) } : [], title: ready ? center : "—", subtitle: subtitle)
                        .frame(width: 92, height: 92)
                    VStack(spacing: 8) {
                        ForEach(items) { item in
                            HStack(spacing: 7) {
                                Circle().fill(item.color).frame(width: 6, height: 6)
                                if let path = item.iconPath {
                                    AppIcon(path: path.isEmpty ? nil : path, size: 15)
                                }
                                Text(item.name).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(item.value).foregroundStyle(Palette.secondary).monospacedDigit().lineLimit(1)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
            }
        }
    }
}
