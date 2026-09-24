import AppKit
import IOKit
import SwiftUI
import UniformTypeIdentifiers

enum ShareKind: String, CaseIterable, Identifiable {
    case memory = "Memory", topApps = "Top Apps", cpu = "CPU", dashboard = "Dashboard"
    var id: String { rawValue }
}

enum Machine {
    /// "MacBook Pro · M5 Pro"
    static let displayName: String = {
        var model = "Mac"
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            if let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data {
                let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                model = name.components(separatedBy: " (").first ?? name
            }
        }
        let chip = Sysctl.string("machdep.cpu.brand_string").replacingOccurrences(of: "Apple ", with: "")
        return chip.isEmpty ? model : "\(model) · \(chip)"
    }()
}

/// 1200×630 image (600×315 pt at 2×) sized for link previews and social posts.
struct ShareCard: View {
    let kind: ShareKind
    let dark: Bool
    let snapshot: Snapshot
    let memoryTotal: Double
    let cores: Int

    static let size = CGSize(width: 600, height: 315)

    private var ink: Color { dark ? .white : Color(hex: 0x1C1C1E) }
    private var muted: Color { ink.opacity(0.55) }
    private var faint: Color { ink.opacity(dark ? 0.1 : 0.07) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconBadge(symbol: "waveform.path.ecg", color: Palette.blue, size: 24)
                Text("iStats").font(.system(size: 17, weight: .bold))
                Spacer()
                Text(Machine.displayName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(muted)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 18)
            Text(Date.now.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10.5))
                .foregroundStyle(muted)
        }
        .foregroundStyle(ink)
        .padding(26)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            LinearGradient(colors: dark ? [Color(hex: 0x1C1C22), Color(hex: 0x0B0B0F)] : [.white, Color(hex: 0xF0F1F6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .fontDesign(.rounded)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .memory: memory
        case .cpu: cpu
        case .topApps: topApps
        case .dashboard: dashboard
        }
    }

    private var memory: some View {
        let m = snapshot.memory
        let total = max(m.total, 1)
        let parts: [(String, Double, Color)] = [
            ("App", m.app, MemoryColors.app), ("Wired", m.wired, MemoryColors.wired),
            ("Compressed", m.compressed, MemoryColors.compressed), ("Cached", m.cached, MemoryColors.cached),
        ]
        return HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory in use").font(.system(size: 12.5)).foregroundStyle(muted)
                big(Format.memoryParts(m.used))
                Text("of \(Int((memoryTotal / 1_073_741_824).rounded())) GB").font(.system(size: 13)).foregroundStyle(muted)
                Spacer(minLength: 12)
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(parts, id: \.0) { part in
                            Rectangle().fill(part.2).frame(width: max(geometry.size.width * part.1 / total - 2, 0))
                        }
                        Spacer(minLength: 0)
                    }
                    .background(faint)
                    .clipShape(Capsule())
                }
                .frame(height: 12)
                HStack(spacing: 12) {
                    ForEach(parts, id: \.0) { part in
                        HStack(spacing: 4) {
                            Circle().fill(part.2).frame(width: 7, height: 7)
                            Text(part.0).font(.system(size: 10.5)).foregroundStyle(muted)
                        }
                    }
                }
            }
            .frame(width: 290, alignment: .leading)
            appList("Top apps", apps: snapshot.byMemory, value: \.memory, format: Format.memory, color: Palette.purple)
        }
    }

    private var cpu: some View {
        let usage = snapshot.cpuUser + snapshot.cpuSystem
        return HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CPU").font(.system(size: 12.5)).foregroundStyle(muted)
                big((String(Int(usage.rounded())), "%"))
                Text("\(cores) cores · load \(String(format: "%.2f", snapshot.load))").font(.system(size: 13)).foregroundStyle(muted)
                Spacer(minLength: 12)
                AreaChart(values: snapshot.cpuHistory.values, maximum: 100, color: Palette.blue, showsGrid: false, lineWidth: 2)
                    .frame(height: 56)
            }
            .frame(width: 290, alignment: .leading)
            appList("Busiest apps", apps: snapshot.byCPU, value: \.cpu, format: Format.percentFine, color: Palette.blue)
        }
    }

    private var topApps: some View {
        HStack(alignment: .top, spacing: 30) {
            appList("By memory", apps: snapshot.byMemory, value: \.memory, format: Format.memory, color: Palette.purple, count: 5)
            appList("By CPU", apps: snapshot.byCPU, value: \.cpu, format: Format.percentFine, color: Palette.blue, count: 5)
        }
    }

    private var dashboard: some View {
        let s = snapshot
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            tile(.cpu, Format.percent(s.cpuUser + s.cpuSystem), s.cpuHistory.values, 100)
            tile(.memory, Format.memory(s.memory.used), s.memoryHistory.values, memoryTotal)
            tile(.gpu, Format.percent(s.gpu), s.gpuHistory.values, 100)
            tile(.network, "↓ " + Format.rate(s.download), s.networkHistory.values, nil)
            tile(.disk, Format.storage(s.disk.free) + " free", nil, nil, fraction: s.disk.total > 0 ? s.disk.used / s.disk.total : 0)
            if s.battery.present {
                tile(.battery, Format.percent(s.battery.percent), nil, nil, fraction: s.battery.percent / 100)
            } else {
                tile(.battery, Format.watts(s.powerAllApps), nil, nil, fraction: nil)
            }
        }
    }

    private func big(_ parts: (String, String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.0).font(.system(size: 54, weight: .bold)).monospacedDigit()
            Text(parts.1).font(.system(size: 22, weight: .semibold)).foregroundStyle(muted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func appList(_ title: String, apps: [AppUsage], value: KeyPath<AppUsage, Double>,
                         format: @escaping (Double) -> String, color: Color, count: Int = 4) -> some View {
        let shown = Array(apps.prefix(count))
        let peak = max(shown.first.map { $0[keyPath: value] } ?? 1, 1e-9)
        return VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(muted)
            ForEach(shown) { app in
                VStack(spacing: 5) {
                    HStack(spacing: 8) {
                        AppIcon(path: app.iconPath, size: 18)
                        Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(format(app[keyPath: value])).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    }
                    ProgressBar(fraction: app[keyPath: value] / peak, color: color, height: 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ tab: Tab, _ value: String, _ series: [Float]?, _ maximum: Double?, fraction: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tab.color)
                Text(tab.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(muted)
            }
            Text(value).font(.system(size: 19, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Group {
                if let series {
                    SparkBars(values: series, maximum: maximum, color: tab.color, slots: 24)
                } else if let fraction {
                    VStack { Spacer(); ProgressBar(fraction: fraction, color: tab.color, height: 6); Spacer() }
                } else {
                    Color.clear
                }
            }
            .frame(height: 22)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(faint))
    }
}

/// Sheet for picking a card, previewing it and saving or copying the PNG.
struct ExportSheet: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ShareKind.memory
    @State private var dark = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Picker("", selection: $kind) {
                    ForEach(ShareKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Picker("", selection: $dark) {
                    Image(systemName: "sun.max.fill").tag(false)
                    Image(systemName: "moon.fill").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            card
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            HStack {
                Text("1200 × 630 PNG").font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy") { copy() }
                Button("Save…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .prominentButton(Palette.blue)
            }
        }
        .padding(20)
        .fontDesign(.rounded)
        .onChange(of: kind) { copied = false }
        .onChange(of: dark) { copied = false }
    }

    private var card: ShareCard {
        ShareCard(kind: kind, dark: dark, snapshot: monitor.snapshot, memoryTotal: monitor.memoryTotal, cores: monitor.cores)
    }

    @MainActor
    private func render() -> NSImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        return renderer.nsImage
    }

    private func png() -> Data? {
        guard let image = render(), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func copy() {
        guard let data = png() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        copied = true
    }

    private func save() {
        guard let data = png() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "iStats \(kind.rawValue).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
        dismiss()
    }
}
