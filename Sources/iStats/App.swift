import AppKit
import SwiftUI

@main
struct IStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("iStats", id: "main") {
            RootView()
                .environment(Monitor.shared)
                .fontDesign(.rounded)
                .frame(minWidth: 940, minHeight: 640)
                .background(WindowObserver())
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1040, height: 740)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            PopoverView().environment(Monitor.shared).fontDesign(.rounded)
        } label: {
            MenuBarLabel().environment(Monitor.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Monitor.shared
        Notifier.shared.setUp()
    }

    /// Closing the window keeps iStats running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Monitor.shared.showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Monitor.shared.shutdown()
    }
}

/// Reports main-window visibility so sampling only does the work the screen needs, and hides the
/// Dock icon while only the menu bar item is left.
private struct WindowObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ObserverView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ObserverView: NSView {
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            NSApp.setActivationPolicy(.regular)
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak window] _ in
                Monitor.shared.setMainWindowVisible(window?.occlusionState.contains(.visible) ?? false)
            })
            tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Monitor.shared.setMainWindowVisible(false)
                NSApp.setActivationPolicy(.accessory)
            })
            Monitor.shared.setMainWindowVisible(window.occlusionState.contains(.visible))
        }
    }
}

struct RootView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @State private var exporting = false

    var body: some View {
        @Bindable var monitor = monitor
        ScrollView {
            content
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .padding(.top, 4)
        }
        .background(GlassBackground().ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) {
                TabBar(selection: $monitor.tab)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Export as Image")
                    .keyboardShortcut("e", modifiers: .command)
            }
        }
        .sheet(isPresented: $exporting) { ExportSheet().environment(monitor) }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { monitor.openMainWindow = { openWindow(id: "main") } }
    }

    @ViewBuilder private var content: some View {
        switch monitor.tab {
        case .overview: OverviewView()
        case .cpu: CPUView()
        case .memory: MemoryView()
        case .disk: DiskView()
        case .network: NetworkView()
        case .gpu: GPUView()
        case .battery: BatteryView()
        case .projects: ProjectsView()
        }
    }
}

struct TabBar: View {
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Tab.allCases.enumerated()), id: \.element) { index, tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon).font(.system(size: 11, weight: .medium))
                        Text(tab.title).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(selected ? tab.color : Color.primary.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(selected ? tab.color.opacity(0.22) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .padding(4)
        .modifier(TabBarChrome())
        .fixedSize()
    }
}

/// macOS 26 already wraps toolbar items in Liquid Glass; older systems get a translucent capsule.
private struct TabBarChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else {
            content.glassCapsule()
        }
    }
}
