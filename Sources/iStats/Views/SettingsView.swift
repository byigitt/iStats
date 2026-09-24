import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.menuBarStyle) private var menuBarStyle = MenuBarStyle.figure
    @AppStorage(Prefs.alertMinutes) private var minutes = 10
    @AppStorage(Prefs.cpuAlerts) private var cpuAlerts = true
    @AppStorage(Prefs.cpuThreshold) private var cpuThreshold = 50.0
    @AppStorage(Prefs.memoryAlerts) private var memoryAlerts = true
    @AppStorage(Prefs.memoryGrowth) private var memoryGrowth = 1.0
    @AppStorage(Prefs.diskAlerts) private var diskAlerts = true
    @AppStorage(Prefs.diskThreshold) private var diskThreshold = 50.0
    @AppStorage(Prefs.networkAlerts) private var networkAlerts = false
    @AppStorage(Prefs.networkThreshold) private var networkThreshold = 10.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                row("waveform.path.ecg", Palette.blue, "Menu bar item") {
                    Picker("", selection: $menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section {
                alert("cpu", Palette.blue, "An app keeps the CPU busy", isOn: $cpuAlerts) {
                    Slider(value: $cpuThreshold, in: 20...90, step: 5) { Text("Above") }
                    Text("\(Int(cpuThreshold))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                alert("memorychip", Palette.purple, "An app keeps using more memory", isOn: $memoryAlerts) {
                    Picker("Growing by", selection: $memoryGrowth) {
                        ForEach([0.5, 1.0, 2.0], id: \.self) { Text("\($0.formatted()) GB an hour").tag($0) }
                    }
                }
                alert("internaldrive.fill", Palette.amber, "An app hammers the disk", isOn: $diskAlerts) {
                    Picker("Writing", selection: $diskThreshold) {
                        ForEach([20.0, 50.0, 100.0], id: \.self) { Text("\(Int($0)) MB/s").tag($0) }
                    }
                }
                alert("globe", Palette.teal, "Your Mac keeps downloading", isOn: $networkAlerts) {
                    Picker("Above", selection: $networkThreshold) {
                        ForEach([5.0, 10.0, 25.0], id: \.self) { Text("\(Int($0)) MB/s").tag($0) }
                    }
                }
                row("clock.fill", Palette.gray, "For at least") {
                    Picker("", selection: $minutes) {
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Checked on your Mac only. Each app is reported at most once an hour.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }

            Section {
                row("power", Palette.green, "Open at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
            }
        }
        .formStyle(.grouped)
        .fontDesign(.rounded)
        .frame(width: 500)
        .fixedSize()
    }

    private func row<Trailing: View>(_ symbol: String, _ color: Color, _ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, color: color, size: 24)
            Text(title)
            Spacer()
            trailing()
        }
    }

    @ViewBuilder
    private func alert<Detail: View>(_ symbol: String, _ color: Color, _ title: String, isOn: Binding<Bool>,
                                     @ViewBuilder detail: () -> Detail) -> some View {
        row(symbol, color, title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .onChange(of: isOn.wrappedValue) { _, enabled in if enabled { Notifier.shared.requestAuthorization() } }
        }
        if isOn.wrappedValue {
            HStack { detail() }.padding(.leading, 34)
        }
    }
}
