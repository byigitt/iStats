import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview, cpu, memory, disk, network, gpu, battery, projects

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .projects: "Projects"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "globe"
        case .gpu: "square.3.layers.3d"
        case .battery: "battery.75percent"
        case .projects: "folder"
        }
    }

    var color: Color {
        switch self {
        case .overview, .cpu: Palette.blue
        case .memory: Palette.purple
        case .disk: Palette.amber
        case .network: Palette.teal
        case .gpu: Palette.pink
        case .battery: Palette.green
        case .projects: Palette.orange
        }
    }
}

enum Palette {
    /// Translucent so the Liquid Glass window background shows through, like iOS widgets.
    static let card = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.07)
    static let secondary = Color.primary.opacity(0.55)
    static let tertiary = Color.primary.opacity(0.32)
    static let hover = Color.primary.opacity(0.045)

    static let blue = Color(hex: 0x3D8BF2)
    static let purple = Color(hex: 0x9D8CF7)
    static let amber = Color(hex: 0xE3A020)
    static let teal = Color(hex: 0x2DB685)
    static let pink = Color(hex: 0xE35C8D)
    static let green = Color(hex: 0x3AC34C)
    static let orange = Color(hex: 0xEE6A2F)
    static let red = Color(hex: 0xE5533D)
    static let yellow = Color(hex: 0xE8C23A)
    static let gray = Color(hex: 0x8E8E93)
}

extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Format {
    private static let gibibyte = 1_073_741_824.0

    /// Memory sizes, binary units like Activity Monitor ("51.73 GB", "458 MB").
    static func memoryParts(_ bytes: Double) -> (String, String) {
        let value = max(bytes, 0)
        if value >= gibibyte { return (String(format: "%.2f", value / gibibyte), "GB") }
        return (String(format: "%.0f", value / 1_048_576), "MB")
    }

    static func memory(_ bytes: Double) -> String { join(memoryParts(bytes)) }

    /// Storage sizes, decimal units like Finder ("479.72 GB").
    static func storageParts(_ bytes: Double) -> (String, String) {
        let value = max(bytes, 0)
        if value >= 1e12 { return (String(format: "%.2f", value / 1e12), "TB") }
        if value >= 1e9 { return (String(format: "%.2f", value / 1e9), "GB") }
        return (String(format: "%.0f", value / 1e6), "MB")
    }

    static func storage(_ bytes: Double) -> String { join(storageParts(bytes)) }

    /// Traffic totals ("4.8 GB", "212 GB").
    static func total(_ bytes: Double) -> String {
        let value = max(bytes, 0)
        let (scaled, unit): (Double, String) =
            value >= 1e12 ? (value / 1e12, "TB") : value >= 1e9 ? (value / 1e9, "GB") : value >= 1e6 ? (value / 1e6, "MB") : (value / 1e3, "kB")
        return String(format: scaled < 100 ? "%.1f %@" : "%.0f %@", scaled, unit)
    }

    static func rateParts(_ bytesPerSecond: Double) -> (String, String) {
        let value = max(bytesPerSecond, 0)
        if value >= 1e9 { return (String(format: "%.1f", value / 1e9), "GB/s") }
        if value >= 1e6 { return (String(format: "%.1f", value / 1e6), "MB/s") }
        return (String(format: "%.0f", value / 1e3), "kB/s")
    }

    static func rate(_ bytesPerSecond: Double) -> String { join(rateParts(bytesPerSecond)) }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func percentFine(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    static func watts(_ value: Double) -> String {
        value < 1 ? "\(Int((value * 1000).rounded())) mW" : String(format: "%.1f W", value)
    }

    /// "2h 19m", "45m"
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// "45s", "2h 19m"
    static func cpuTime(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : duration(seconds)
    }

    static func temperature(_ celsius: Double) -> String { "\(Int(celsius.rounded()))°" }

    /// "3d 4h", "5h 12m"
    static func uptime(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h \(minutes % 60)m"
    }

    /// "20 min", "2 hours", "3 days"
    static func span(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }

    private static func join(_ parts: (String, String)) -> String { "\(parts.0) \(parts.1)" }
}
