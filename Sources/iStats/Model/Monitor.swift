import AppKit
import Observation

@Observable
final class Monitor {
    static let shared = Monitor()

    private(set) var snapshot = Snapshot()
    var tab: Tab { didSet { if tab != oldValue { demandChanged() } } }
    var popoverTab: Tab = .overview { didSet { if popoverTab != oldValue { demandChanged() } } }
    var historyRange = HistoryRange.live { didSet { if historyRange != oldValue { engine.setHistoryRange(historyRange) } } }

    let cores: Int
    let performanceCores: Int
    let efficiencyCores: Int
    let memoryTotal: Double
    let gpuName: String
    let bootTime = Sysctl.bootTime

    @ObservationIgnored private let engine = Engine()
    @ObservationIgnored private var mainVisible = false
    @ObservationIgnored private var popoverOpen = false
    /// Set by a SwiftUI view that has access to `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    private init() {
        Prefs.registerDefaults()
        tab = .overview
        let cores = engine.cpuCores
        self.cores = cores.total
        performanceCores = cores.performance
        efficiencyCores = cores.efficiency
        memoryTotal = engine.memoryTotal
        gpuName = engine.gpu.name

        engine.onUpdate = { [weak self] snapshot in self?.snapshot = snapshot }
        engine.onAlert = { Notifier.shared.post($0) }
        Notifier.shared.onOpen = { [weak self] kind in self?.showMainWindow(tab: Tab(rawValue: kind) ?? .cpu) }
        engine.start(showing: [])
    }

    func setMainWindowVisible(_ visible: Bool) {
        guard visible != mainVisible else { return }
        mainVisible = visible
        demandChanged()
    }

    func setPopoverOpen(_ open: Bool) {
        guard open != popoverOpen else { return }
        popoverOpen = open
        demandChanged()
    }

    private func demandChanged() {
        var tabs: Set<Tab> = []
        if mainVisible { tabs.insert(tab) }
        if popoverOpen { tabs.insert(popoverTab) }
        engine.update(showing: tabs)
    }

    func showMainWindow(tab: Tab? = nil) {
        if let tab { self.tab = tab }
        NSApp.setActivationPolicy(.regular)
        if let openMainWindow {
            openMainWindow()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop(_ projects: [Project]) {
        engine.terminate(pids: projects.flatMap(\.pids))
    }

    func signal(_ pids: [Int32], force: Bool) {
        engine.signal(pids, force: force)
    }

    func shutdown() { engine.shutdown() }
}
