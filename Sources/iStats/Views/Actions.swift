import AppKit
import SwiftUI

extension AppUsage {
    /// Quitting these logs the user out or takes the session down with it.
    var canQuit: Bool {
        let protected = ["loginwindow", "WindowServer", "kernel_task", "launchd", "Dock", "SystemUIServer", "ControlCenter"]
        return !pids.isEmpty && !protected.contains(name) && !id.hasPrefix("/usr/libexec/") && !id.hasPrefix("/usr/sbin/")
            && !id.hasPrefix("/sbin/")
    }
}

enum AppActions {
    static func confirmQuit(_ app: AppUsage, force: Bool) {
        let count = app.pids.count
        let noun = count == 1 ? "1 process" : "\(count) processes"
        let confirmed = confirm(
            title: "\(force ? "Force Quit" : "Quit") \(app.name)?",
            message: "\(noun) will close." + (force ? " Unsaved changes will be lost." : ""),
            action: force ? "Force Quit" : "Quit", iconPath: app.iconPath, destructive: force)
        guard confirmed else { return }

        if app.id == Bundle.main.bundlePath {
            NSApp.terminate(nil)
            return
        }
        let running = app.iconPath.map { path in
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
        } ?? []
        for application in running {
            if force { application.forceTerminate() } else { application.terminate() }
        }
        // Background helpers and command-line tools have no NSRunningApplication to ask politely.
        if running.isEmpty || force {
            Monitor.shared.signal(app.pids, force: force)
        }
    }

    static func confirmQuit(pid: Int32, of app: AppUsage, force: Bool) {
        let name = processName(pid)
        let confirmed = confirm(
            title: "\(force ? "Force Quit" : "Quit") \(name)?",
            message: "Process \(pid) of \(app.name) will close.",
            action: force ? "Force Quit" : "Quit", iconPath: app.iconPath, destructive: force)
        if confirmed { Monitor.shared.signal([pid], force: force) }
    }

    static func processName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return name.isEmpty ? "Process \(pid)" : name
    }

    private static func confirm(title: String, message: String, action: String, iconPath: String?, destructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let path = iconPath, let icon = IconCache.bundleIcon(at: path, pixels: 128) {
            alert.icon = NSImage(cgImage: icon, size: NSSize(width: 64, height: 64))
        }
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension View {
    /// Right-click menu for an app row: quit, force quit, or end a single process.
    func appActions(_ app: AppUsage) -> some View {
        contextMenu {
            if app.canQuit {
                Button("Quit \(app.name)…") { AppActions.confirmQuit(app, force: false) }
                Button("Force Quit \(app.name)…") { AppActions.confirmQuit(app, force: true) }
                if app.pids.count > 1 {
                    Menu("Processes") { ProcessItems(app: app) }
                }
            }
            if let path = app.iconPath {
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }
}

/// Resolved lazily so process names are only looked up when the submenu opens.
private struct ProcessItems: View {
    let app: AppUsage

    var body: some View {
        ForEach(app.pids.prefix(24), id: \.self) { pid in
            Menu("\(AppActions.processName(pid)) — \(pid)") {
                Button("Quit…") { AppActions.confirmQuit(pid: pid, of: app, force: false) }
                Button("Force Quit…") { AppActions.confirmQuit(pid: pid, of: app, force: true) }
            }
        }
        if app.pids.count > 24 {
            Text("\(app.pids.count - 24) more…")
        }
    }
}
