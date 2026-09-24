import AppKit
import OSLog
import UserNotifications

enum Prefs {
    static let menuBarStyle = "menuBarStyle"
    static let alertMinutes = "alertMinutes"
    static let cpuAlerts = "cpuAlertsEnabled"
    static let cpuThreshold = "cpuAlertThreshold"
    static let memoryAlerts = "memoryAlertsEnabled"
    static let memoryGrowth = "memoryAlertGrowthGB"
    static let diskAlerts = "diskAlertsEnabled"
    static let diskThreshold = "diskAlertMBps"
    static let networkAlerts = "networkAlertsEnabled"
    static let networkThreshold = "networkAlertMBps"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            menuBarStyle: MenuBarStyle.figure.rawValue,
            alertMinutes: 10,
            cpuAlerts: true,
            cpuThreshold: 50.0,
            memoryAlerts: true,
            memoryGrowth: 1.0,
            diskAlerts: true,
            diskThreshold: 50.0,
            networkAlerts: false,
            networkThreshold: 10.0,
        ])
    }

    static var anyAlertsEnabled: Bool {
        let defaults = UserDefaults.standard
        return [cpuAlerts, memoryAlerts, diskAlerts, networkAlerts].contains { defaults.bool(forKey: $0) }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, figure, graph, stacked
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct AppAlert {
    let id: String
    let title: String
    let body: String
    let iconPath: String?
}

/// Watches per-app usage for sustained misbehavior. Each rule reports an app at most once per cooldown.
final class AppWatch {
    /// Sliding average of one metric for apps that crossed half the threshold.
    private struct Sustained {
        struct Window {
            var name: String
            var iconPath: String?
            var samples: [Float] = []
            var sum = 0.0
        }

        var windows: [String: Window] = [:]

        mutating func feed(_ apps: [AppUsage], value: (AppUsage) -> Double, threshold: Double, length: Int) -> [(Window, Double)] {
            var current: [String: AppUsage] = [:]
            for app in apps where value(app) > 0 { current[app.id] = app }
            for app in current.values where value(app) >= threshold / 2 && windows[app.id] == nil {
                windows[app.id] = Window(name: app.name, iconPath: app.iconPath)
            }
            var hits: [(Window, Double)] = []
            for key in Array(windows.keys) {
                guard var window = windows[key] else { continue }
                let sample = current[key].map(value) ?? 0
                window.samples.append(Float(sample))
                window.sum += sample
                while window.samples.count > length { window.sum -= Double(window.samples.removeFirst()) }
                let average = window.sum / Double(window.samples.count)
                if window.samples.count >= 30, average < threshold / 4 {
                    windows[key] = nil
                    continue
                }
                windows[key] = window
                if window.samples.count >= length, average >= threshold { hits.append((window, average)) }
            }
            return hits
        }
    }

    /// One memory reading per minute for the last hour.
    private struct Trail {
        var name: String
        var iconPath: String?
        var samples: [Float] = []
    }

    private var cpu = Sustained()
    private var disk = Sustained()
    private var network: [Float] = []
    private var trails: [String: Trail] = [:]
    private var lastAlert: [String: Double] = [:]

    func feed(_ apps: [AppUsage], download: Double, interval: Double, tick: Int) -> (alerts: [AppAlert], networkAverage: Double?) {
        let defaults = UserDefaults.standard
        let minutes = max(defaults.integer(forKey: Prefs.alertMinutes), 1)
        let length = Int(Double(minutes * 60) / interval)
        let duration = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        var alerts: [AppAlert] = []

        if defaults.bool(forKey: Prefs.cpuAlerts) {
            for (window, average) in cpu.feed(apps, value: \.cpu, threshold: defaults.double(forKey: Prefs.cpuThreshold), length: length)
            where allow("cpu" + window.name, cooldown: 3600) {
                alerts.append(AppAlert(
                    id: "cpu-" + window.name, title: "\(window.name) is keeping the CPU busy",
                    body: "\(Int(average.rounded()))% on average for \(duration).", iconPath: window.iconPath))
            }
        } else {
            cpu.windows.removeAll()
        }

        if defaults.bool(forKey: Prefs.diskAlerts) {
            let threshold = defaults.double(forKey: Prefs.diskThreshold) * 1e6
            for (window, average) in disk.feed(apps, value: \.writeRate, threshold: threshold, length: length)
            where allow("disk" + window.name, cooldown: 3600) {
                alerts.append(AppAlert(
                    id: "disk-" + window.name, title: "\(window.name) is hammering the disk",
                    body: "Writing \(Format.rate(average)) on average for \(duration).", iconPath: window.iconPath))
            }
        } else {
            disk.windows.removeAll()
        }

        if defaults.bool(forKey: Prefs.memoryAlerts), tick % Int(60 / interval) == 0 {
            alerts += feedMemory(apps, growth: defaults.double(forKey: Prefs.memoryGrowth) * 1_073_741_824)
        } else if !defaults.bool(forKey: Prefs.memoryAlerts) {
            trails.removeAll()
        }

        var networkAverage: Double?
        if defaults.bool(forKey: Prefs.networkAlerts) {
            network.append(Float(download))
            if network.count > length { network.removeFirst(network.count - length) }
            let average = Double(network.reduce(0, +)) / Double(network.count)
            if network.count >= length, average >= defaults.double(forKey: Prefs.networkThreshold) * 1e6,
               allow("network", cooldown: 3600) {
                networkAverage = average
            }
        } else {
            network.removeAll()
        }
        return (alerts, networkAverage)
    }

    func networkAlert(app: AppUsage?, average: Double) -> AppAlert {
        let minutes = max(UserDefaults.standard.integer(forKey: Prefs.alertMinutes), 1)
        return AppAlert(
            id: "network", title: "\(app?.name ?? "Your Mac") keeps downloading",
            body: "\(Format.rate(average)) on average for \(minutes) minute\(minutes == 1 ? "" : "s").",
            iconPath: app?.iconPath)
    }

    private func feedMemory(_ apps: [AppUsage], growth: Double) -> [AppAlert] {
        let tracked = apps.sorted { $0.memory > $1.memory }.prefix(20)
        let keep = Set(tracked.map(\.id))
        trails = trails.filter { keep.contains($0.key) }
        var alerts: [AppAlert] = []
        for app in tracked {
            var trail = trails[app.id] ?? Trail(name: app.name, iconPath: app.iconPath)
            trail.samples.append(Float(app.memory))
            if trail.samples.count > 61 { trail.samples.removeFirst() }
            trails[app.id] = trail
            guard trail.samples.count == 61, let first = trail.samples.first, let peak = trail.samples.max() else { continue }
            let now = Double(trail.samples[60])
            // Steady growth only: still near its peak, not a spike that already came back down.
            guard now - Double(first) >= growth, now >= Double(peak) * 0.9, allow("memory" + app.id, cooldown: 3 * 3600) else { continue }
            alerts.append(AppAlert(
                id: "memory-" + app.name, title: "\(app.name) keeps using more memory",
                body: "Up \(Format.memory(now - Double(first))) in an hour, now \(Format.memory(now)).", iconPath: app.iconPath))
        }
        return alerts
    }

    private func allow(_ key: String, cooldown: Double) -> Bool {
        let now = Date().timeIntervalSince1970
        guard now - (lastAlert[key] ?? 0) > cooldown else { return false }
        lastAlert[key] = now
        return true
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private static let log = Logger(subsystem: "dev.istats.iStats", category: "alerts")
    var onOpen: ((String) -> Void)?

    /// UserNotifications requires a real app bundle; `swift run` binaries have none.
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if Prefs.anyAlertsEnabled { requestAuthorization() }
    }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ alert: AppAlert) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.userInfo = ["kind": String(alert.id.prefix { $0 != "-" })]
        if let attachment = iconAttachment(for: alert.iconPath) { content.attachments = [attachment] }
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.log.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
        Self.log.notice("Posted alert \(alert.id, privacy: .public)")
    }

    private func iconAttachment(for path: String?) -> UNNotificationAttachment? {
        guard let path,
              let icon = IconCache.bundleIcon(at: path, pixels: 128),
              let png = NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("istats-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: url)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let kind = response.notification.request.content.userInfo["kind"] as? String ?? "cpu"
        DispatchQueue.main.async { self.onOpen?(kind) }
        completionHandler()
    }
}
