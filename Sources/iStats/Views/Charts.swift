import SwiftUI

/// Bar sparkline used on Overview cards. Bars are right-aligned so new samples enter from the right.
struct SparkBars: View {
    let values: [Float]
    let maximum: Double?
    let color: Color
    var slots = 44

    var body: some View {
        Canvas { context, size in
            let recent = values.suffix(slots)
            let peak = maximum ?? max(Double(recent.max() ?? 0) * 1.1, 1)
            let slot = size.width / CGFloat(slots)
            let width = slot * 0.6
            let usable = size.height - 4
            let offset = slots - recent.count
            for index in 0..<slots {
                let value = index >= offset ? Double(recent[recent.startIndex + index - offset]) : 0
                let height = max(3, CGFloat(min(value / peak, 1)) * usable)
                let rect = CGRect(x: CGFloat(index) * slot + (slot - width) / 2, y: size.height - 2 - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 3), with: .color(color.opacity(index >= offset ? 1 : 0.35)))
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.13)))
    }
}

/// Line + gradient area chart used in detail tabs.
struct AreaChart: View {
    let values: [Float]
    let maximum: Double?
    let color: Color
    var showsGrid = true
    var lineWidth: CGFloat = 2
    /// Number of samples the full width represents; shorter histories are right-aligned.
    var capacity = Series.capacity

    var body: some View {
        Canvas { context, size in
            let grid = GraphicsContext.Shading.color(.primary.opacity(0.08))
            for line in 0...3 where showsGrid {
                let y = (size.height - 1) * CGFloat(line) / 3 + 0.5
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: grid, lineWidth: 1)
            }
            let values = values.suffix(capacity)
            guard values.count > 1 else { return }

            let peak = maximum ?? max(Double(values.max() ?? 0) * 1.15, 1)
            let step = size.width / CGFloat(capacity - 1)
            let start = size.width - CGFloat(values.count - 1) * step
            let usable = size.height - 4
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: start + CGFloat(index) * step,
                    y: size.height - 1 - CGFloat(min(Double(value) / peak, 1)) * usable
                )
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.38), color.opacity(0.04)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

struct Donut: View {
    let segments: [(Double, Color)]
    let title: String
    let subtitle: String
    var lineWidth: CGFloat = 11

    var body: some View {
        ZStack {
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2 - lineWidth / 2
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var track = Path()
                track.addArc(center: center, radius: radius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                context.stroke(track, with: .color(.primary.opacity(0.07)), lineWidth: lineWidth)

                let visible = segments.filter { $0.0 > 0 }
                let total = visible.reduce(0) { $0 + $1.0 }
                guard total > 0 else { return }
                let gap = visible.count > 1 ? 2.5 : 0
                var angle = -90.0
                for (value, color) in visible {
                    let sweep = value / total * 360
                    if sweep > gap {
                        var arc = Path()
                        arc.addArc(center: center, radius: radius, startAngle: .degrees(angle + gap / 2),
                                   endAngle: .degrees(angle + sweep - gap / 2), clockwise: false)
                        context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    }
                    angle += sweep
                }
            }
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            .lineLimit(1)
            .padding(lineWidth + 5)
        }
    }
}

/// Bars for a history range; negative values mark periods with no data and draw nothing.
struct HistoryBars: View {
    let values: [Float]
    let maximum: Double?
    let color: Color

    var body: some View {
        Canvas { context, size in
            let grid = GraphicsContext.Shading.color(.primary.opacity(0.08))
            for line in 0...3 {
                let y = (size.height - 1) * CGFloat(line) / 3 + 0.5
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: grid, lineWidth: 1)
            }
            guard !values.isEmpty else { return }
            let peak = maximum ?? max(Double(values.max() ?? 0) * 1.15, 1)
            let slot = size.width / CGFloat(values.count)
            let width = max(slot * 0.62, 2)
            for (index, value) in values.enumerated() where value >= 0 {
                let height = max(3, CGFloat(min(Double(value) / peak, 1)) * (size.height - 4))
                let rect = CGRect(x: CGFloat(index) * slot + (slot - width) / 2, y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(width / 2.5, 4)),
                             with: .linearGradient(Gradient(colors: [color, color.opacity(0.65)]),
                                                   startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            }
        }
    }
}

/// iOS-style segmented capsule for Live / 12h / 24h / 7d / 30d.
struct RangePicker: View {
    @Binding var selection: HistoryRange
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryRange.allCases) { range in
                let selected = range == selection
                Button { selection = range } label: {
                    Text(range.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? color : Palette.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(selected ? color.opacity(0.18) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}
