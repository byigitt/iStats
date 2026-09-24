import AppKit
import ImageIO
import SwiftUI

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardBackground()
    }
}

extension View {
    func cardBackground(radius: CGFloat = 20) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.card))
    }

    /// Liquid Glass on macOS 26, a translucent capsule before that.
    @ViewBuilder func glassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            background(Capsule().fill(Palette.card))
        }
    }

    /// Tinted, prominent glass button on macOS 26; a filled capsule before that.
    @ViewBuilder func prominentButton(_ tint: Color) -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint).buttonBorderShape(.capsule)
        }
    }
}

/// Settings-style badge: white glyph on a solid rounded square.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
    }
}

/// Full-window Liquid Glass (NSGlassEffectView) with a behind-window blur fallback.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *) {
            return NSGlassEffectView()
        }
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HeroValue: View {
    let parts: (String, String)
    var size: CGFloat = 38

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(parts.0)
                .font(.system(size: size, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(parts.1)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(Palette.secondary)
        }
        .lineLimit(1)
    }
}

struct PressureBadge: View {
    let level: Int

    var body: some View {
        let (title, symbol, color): (String, String, Color) = switch level {
        case 4...: ("Critical", "exclamationmark.triangle.fill", Palette.red)
        case 2...: ("Elevated", "exclamationmark", Palette.yellow)
        default: ("Normal", "checkmark", Palette.green)
        }
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(title).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.18)))
        .lineLimit(1)
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2)
            context.fill(track, with: .color(color.opacity(0.18)))
            let width = size.width * CGFloat(min(max(fraction, 0), 1))
            guard width > 0 else { return }
            let bar = Path(roundedRect: CGRect(x: 0, y: 0, width: max(width, height), height: size.height), cornerRadius: height / 2)
            context.fill(bar, with: .color(color))
        }
        .frame(height: height)
    }
}

struct AppIcon: View {
    let path: String?
    var size: CGFloat = 26

    var body: some View {
        if let image = IconCache.shared.icon(for: path) {
            Image(decorative: image, scale: 2)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: path == nil ? "terminal.fill" : "app.fill")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .frame(width: size * 0.84, height: size * 0.84)
                .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color.primary.opacity(0.1)))
                .frame(width: size, height: size)
        }
    }
}

/// Reads app icons straight out of each bundle's .icns at the smallest size that is sharp enough.
/// `NSWorkspace.icon(forFile:)` would pull in IconServices, whose caches cost ~100 MB of footprint.
final class IconCache {
    static let shared = IconCache()
    private var icons: [String: CGImage?] = [:]

    func icon(for path: String?) -> CGImage? {
        guard let path else { return nil }
        if let cached = icons[path] { return cached }
        if icons.count > 48 { icons.removeAll() }
        let image = Self.bundleIcon(at: path, pixels: 64)
        icons[path] = image
        return image
    }

    static func bundleIcon(at bundlePath: String, pixels: Int) -> CGImage? {
        let contents = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents")
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
              var name = info["CFBundleIconFile"] as? String, !name.isEmpty
        else { return nil }
        if !name.hasSuffix(".icns") { name += ".icns" }
        let url = contents.appendingPathComponent("Resources").appendingPathComponent(name)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }

        var best: (index: Int, width: Int)?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int
            else { continue }
            let fits = width >= pixels
            let better = switch best {
            case nil: true
            case let current?: fits ? (current.width < pixels || width < current.width) : (current.width < pixels && width > current.width)
            }
            if better { best = (index, width) }
        }
        guard let best else { return nil }
        return CGImageSourceCreateImageAtIndex(source, best.index, options)
    }
}
