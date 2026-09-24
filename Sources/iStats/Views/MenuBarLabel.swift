import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.menuBarStyle) private var style = MenuBarStyle.figure

    var body: some View {
        let s = monitor.snapshot
        let cpu = s.cpuUser + s.cpuSystem
        Group {
            switch style {
            case .icon:
                Image(systemName: "waveform.path.ecg")
            case .figure:
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path.ecg")
                    Text(Format.percent(cpu)).monospacedDigit()
                }
            case .graph:
                Image(nsImage: MenuBarImage.render(GraphLabel(values: Array(s.cpuHistory.values.suffix(10)), cpu: cpu)))
            case .stacked:
                Image(nsImage: MenuBarImage.render(StackedLabel(cpu: cpu, memory: s.memory.used / max(monitor.memoryTotal, 1) * 100)))
            }
        }
        .onAppear { monitor.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Menu bar labels only accept plain text and images, so richer styles are drawn into a template image.
private enum MenuBarImage {
    @MainActor
    static func render(_ content: some View) -> NSImage {
        let renderer = ImageRenderer(content: content.foregroundStyle(.black).fontDesign(.rounded))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct GraphLabel: View {
    let values: [Float]
    let cpu: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 13, weight: .medium))
            Canvas { context, size in
                let slots = 10
                let slot = size.width / CGFloat(slots)
                let offset = slots - values.count
                for index in 0..<slots {
                    let track = CGRect(x: CGFloat(index) * slot + 0.5, y: 0, width: slot - 1, height: size.height)
                    context.fill(Path(roundedRect: track, cornerRadius: 0.8), with: .color(.black.opacity(0.25)))
                }
                for (index, value) in values.enumerated() {
                    let height = max(1.5, CGFloat(min(Double(value) / 100, 1)) * size.height)
                    let rect = CGRect(x: CGFloat(index + offset) * slot + 0.5, y: size.height - height, width: slot - 1, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(.black))
                }
            }
            .frame(width: 24, height: 13)
            Text(Format.percent(cpu)).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
        }
        .frame(height: 18)
    }
}

private struct StackedLabel: View {
    let cpu: Double
    let memory: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: -1.5) {
                line("CPU", cpu)
                line("MEM", memory)
            }
        }
        .fixedSize()
        .frame(height: 20)
    }

    private func line(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 7.5, weight: .bold)).fixedSize().frame(minWidth: 20, alignment: .leading)
            Text(Format.percent(value)).font(.system(size: 9, weight: .semibold)).monospacedDigit()
        }
    }
}
