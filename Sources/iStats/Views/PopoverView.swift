import AppKit
import SwiftUI

/// Compact dashboard shown from the menu bar item.
struct PopoverView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        VStack(alignment: .leading, spacing: 12) {
            IconTabs(selection: $monitor.popoverTab)
            HStack {
                Text(monitor.popoverTab.title.uppercased())
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Palette.secondary)
                Spacer()
                Label("Up \(Format.uptime(Date().timeIntervalSince1970 - monitor.bootTime))", systemImage: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 4)

            Group {
                switch monitor.popoverTab {
                case .overview: PopoverOverview()
                case .projects: PopoverProjects()
                default: PopoverDetail(tab: monitor.popoverTab)
                }
            }

            HStack(spacing: 16) {
                Button("Open iStats") {
                    monitor.showMainWindow(tab: monitor.popoverTab)
                }
                Spacer()
                SettingsLink { Text("Settings…") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { monitor.setPopoverOpen(true) }
        .onDisappear { monitor.setPopoverOpen(false) }
    }
}

private struct IconTabs: View {
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? tab.color : Color.primary.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? tab.color.opacity(0.16) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(4)
        .cardBackground(radius: 18)
    }
}

private struct MiniCard<Footer: View>: View {
    let tab: Tab
    let value: (String, String)
    var leading: String?
    let trailing: String
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tab.color)
                Text(tab.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let leading {
                    Image(systemName: leading).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
                }
                Text(value.0).font(.system(size: 22, weight: .bold)).monospacedDigit()
                Text(value.1).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Spacer(minLength: 2)
                Text(trailing).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            footer.frame(height: 20)
        }
        .padding(10)
        .cardBackground(radius: 18)
        .contentShape(Rectangle())
    }
}

private struct PopoverOverview: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let battery = s.battery
        VStack(spacing: 8) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    card(.cpu, value: (String(Int((s.cpuUser + s.cpuSystem).rounded())), "%"),
                         trailing: String(format: "load %.2f", s.load)) {
                        AreaChart(values: s.cpuHistory.values, maximum: 100, color: Palette.blue, showsGrid: false, lineWidth: 1.5, capacity: 30)
                    }
                    card(.memory, value: Format.memoryParts(s.memory.used),
                         trailing: "of \(Int((monitor.memoryTotal / 1_073_741_824).rounded())) GB") {
                        AreaChart(values: s.memoryHistory.values, maximum: monitor.memoryTotal, color: Palette.purple, showsGrid: false, lineWidth: 1.5, capacity: 30)
                    }
                }
                GridRow {
                    card(.network, value: Format.rateParts(s.download), leading: "arrow.down",
                         trailing: "↑ " + Format.rate(s.upload)) {
                        AreaChart(values: s.networkHistory.values, maximum: nil, color: Palette.teal, showsGrid: false, lineWidth: 1.5, capacity: 30)
                    }
                    card(.disk, value: Format.storageParts(s.disk.free), trailing: "free") {
                        ProgressBar(fraction: s.disk.total > 0 ? s.disk.used / s.disk.total : 0, color: Palette.amber, height: 6)
                    }
                }
                GridRow {
                    card(.gpu, value: (String(Int(s.gpu.rounded())), "%"), trailing: Format.memory(s.gpuMemory)) {
                        AreaChart(values: s.gpuHistory.values, maximum: 100, color: Palette.pink, showsGrid: false, lineWidth: 1.5, capacity: 30)
                    }
                    card(.battery, value: battery.present ? (String(Int(battery.percent.rounded())), "%") : ("—", ""),
                         trailing: batteryTrailing(battery)) {
                        ProgressBar(fraction: battery.percent / 100, color: Palette.green, height: 6)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Busiest Right Now").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                if s.byCPU.isEmpty {
                    Text("Collecting…").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
                ForEach(s.byCPU.prefix(3)) { app in
                    HStack(spacing: 10) {
                        AppIcon(path: app.iconPath, size: 20)
                        Text(app.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", app.cpu)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .appActions(app)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(radius: 18)
            .contentShape(Rectangle())
            .onTapGesture { monitor.popoverTab = .cpu }

            if #available(macOS 14.2, *) { VolumeCard() }
        }
    }

    private func card<Footer: View>(
        _ tab: Tab, value: (String, String), leading: String? = nil, trailing: String, @ViewBuilder footer: () -> Footer
    ) -> some View {
        MiniCard(tab: tab, value: value, leading: leading, trailing: trailing, footer: footer)
            .onTapGesture { monitor.popoverTab = tab }
    }

    private func batteryTrailing(_ battery: BatteryStats) -> String {
        if !battery.present { return "AC power" }
        if let remaining = battery.remaining { return "\(Format.duration(remaining)) left" }
        if let toFull = battery.toFull { return "\(Format.duration(toFull)) to full" }
        return battery.charging ? "charging" : battery.external ? "on AC" : ""
    }
}

/// Hero value, sparkline and the top apps for one metric.
private struct PopoverDetail: View {
    @Environment(Monitor.self) private var monitor
    let tab: Tab

    var body: some View {
        let s = monitor.snapshot
        let config = configuration(s)
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    HeroValue(parts: config.value, size: 30)
                    Spacer()
                    Text(config.caption).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                AreaChart(values: config.series.values, maximum: config.maximum, color: tab.color, showsGrid: false, lineWidth: 1.5, capacity: 30)
                    .frame(height: 54)
            }
            .padding(12)
            .cardBackground(radius: 18)

            VStack(spacing: 9) {
                if config.apps.isEmpty {
                    Text(s.appsReady ? "No activity right now" : "Collecting…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(config.apps.prefix(5)) { app in
                    HStack(spacing: 10) {
                        AppIcon(path: app.iconPath, size: 20)
                        Text(app.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(config.format(app[keyPath: config.metric]))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .appActions(app)
                }
            }
            .padding(12)
            .cardBackground(radius: 18)
        }
    }

    private struct Configuration {
        let value: (String, String)
        let caption: String
        let series: Series
        let maximum: Double?
        let apps: [AppUsage]
        let metric: KeyPath<AppUsage, Double>
        let format: (Double) -> String
    }

    private func configuration(_ s: Snapshot) -> Configuration {
        switch tab {
        case .memory:
            Configuration(value: Format.memoryParts(s.memory.used), caption: "\(Format.memory(s.memory.available)) free",
                          series: s.memoryHistory, maximum: monitor.memoryTotal, apps: s.byMemory, metric: \.memory, format: Format.memory)
        case .disk:
            Configuration(value: Format.rateParts(s.disk.writeRate), caption: "reading \(Format.rate(s.disk.readRate))",
                          series: s.diskHistory, maximum: nil, apps: s.byDisk, metric: \.writeRate, format: Format.rate)
        case .network:
            Configuration(value: Format.rateParts(s.download), caption: "↑ \(Format.rate(s.upload))",
                          series: s.networkHistory, maximum: nil, apps: s.byNetwork, metric: \.download, format: Format.rate)
        case .gpu:
            Configuration(value: (String(Int(s.gpu.rounded())), "%"), caption: monitor.gpuName,
                          series: s.gpuHistory, maximum: 100, apps: s.byGPU, metric: \.gpu, format: Format.percentFine)
        case .battery:
            Configuration(value: s.battery.present ? (String(Int(s.battery.percent.rounded())), "%") : ("—", ""),
                          caption: s.battery.present ? "\(s.battery.statusText) · \(Format.watts(s.battery.watts))" : "No battery",
                          series: s.batteryHistory, maximum: 100, apps: s.byPower, metric: \.watts, format: Format.watts)
        default:
            Configuration(value: (String(Int((s.cpuUser + s.cpuSystem).rounded())), "%"), caption: String(format: "load %.2f", s.load),
                          series: s.cpuHistory, maximum: 100, apps: s.byCPU, metric: \.cpu, format: { String(format: "%.1f%%", $0) })
        }
    }
}

private struct PopoverProjects: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let idle = s.projects.filter(\.isIdleServer)
        VStack(spacing: 8) {
            if !idle.isEmpty {
                HStack {
                    Image(systemName: "moon.fill").foregroundStyle(Palette.orange)
                    Text("\(idle.count) idle dev server\(idle.count == 1 ? "" : "s") · \(Format.memory(idle.reduce(0) { $0 + $1.memory }))")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button("Stop All") { monitor.stop(idle) }
                        .fontWeight(.semibold)
                        .prominentButton(Palette.orange)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.orange.opacity(0.16)))
            }
            VStack(spacing: 9) {
                if s.projects.isEmpty {
                    Text(s.projectsReady ? "No projects running" : "Looking for dev servers…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(s.projects.prefix(7)) { project in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(Palette.orange)
                        Text(project.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        ForEach(project.ports.prefix(2), id: \.self) { Chip(text: String($0), color: Palette.orange) }
                        Text(Format.memory(project.memory))
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                            .frame(minWidth: 58, alignment: .trailing)
                    }
                }
            }
            .padding(12)
            .cardBackground(radius: 18)
        }
    }
}

@available(macOS 14.2, *)
private struct VolumeCard: View {
    private let mixer = VolumeMixer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !mixer.sources.isEmpty {
                HStack {
                    Text("Volume").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text(mixer.failed ? "Allow audio access in Privacy & Security" : "Nothing is recorded")
                        .font(.system(size: 11))
                        .foregroundStyle(mixer.failed ? Palette.orange : Palette.tertiary)
                }
                ForEach(mixer.sources) { source in
                    HStack(spacing: 10) {
                        AppIcon(path: source.iconPath, size: 20)
                        Text(source.name).font(.system(size: 13)).lineLimit(1).frame(width: 84, alignment: .leading)
                        Slider(value: Binding(get: { Double(mixer.volume(for: source)) },
                                              set: { mixer.setVolume(Float($0), for: source) }), in: 0...1)
                            .controlSize(.small)
                        Text(Format.percent(Double(mixer.volume(for: source)) * 100))
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
        .padding(mixer.sources.isEmpty ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if !mixer.sources.isEmpty { Color.clear.cardBackground(radius: 18) } }
        .task {
            while !Task.isCancelled {
                mixer.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
