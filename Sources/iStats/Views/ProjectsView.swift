import AppKit
import SwiftUI

struct ProjectsView: View {
    @Environment(Monitor.self) private var monitor
    @State private var confirming = false

    var body: some View {
        let s = monitor.snapshot
        let idle = s.projects.filter(\.isIdleServer)
        VStack(spacing: 10) {
            if !idle.isEmpty {
                IdleBanner(projects: idle) { confirming = true }
            }
            VStack(spacing: 0) {
                if s.projects.isEmpty {
                    VStack(spacing: 8) {
                        IconBadge(symbol: "folder", color: Palette.orange, size: 36)
                        Text(s.projectsReady ? "No projects running" : "Looking for dev servers…")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Processes running inside a project folder (git repo, package.json, …) show up here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
                ForEach(s.projects) { project in
                    ProjectRow(project: project) { monitor.stop([project]) }
                }
            }
            .padding(6)
            .cardBackground()
        }
        .alert(
            "Stop \(idle.count) idle dev server\(idle.count == 1 ? "" : "s")?",
            isPresented: $confirming
        ) {
            Button("Stop All", role: .destructive) { monitor.stop(idle) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(idle.map(\.name).joined(separator: ", ") + " will be sent a quit signal. Unsaved state in those processes will be lost.")
        }
    }
}

private struct IdleBanner: View {
    let projects: [Project]
    let onStop: () -> Void

    var body: some View {
        let memory = projects.reduce(0) { $0 + $1.memory }
        let ports = projects.flatMap(\.ports).sorted().map(String.init)
        let portText = ports.count > 1 ? "ports " + ports.dropLast().joined(separator: ", ") + " and " + ports.last! : "port " + (ports.first ?? "")
        HStack(spacing: 12) {
            IconBadge(symbol: "moon.fill", color: Palette.orange, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(projects.count) dev server\(projects.count == 1 ? " is" : "s are") running but idle")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Stopping them frees \(Format.memory(memory)) and \(portText).")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            Button("Stop All…", action: onStop)
                .fontWeight(.semibold)
                .controlSize(.large)
                .prominentButton(Palette.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.orange.opacity(0.2)))
    }
}

private struct ProjectRow: View {
    let project: Project
    let onStop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "folder", color: Palette.orange, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(project.kind).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            ForEach(project.ports.prefix(3), id: \.self) { port in
                Chip(text: String(port), color: Palette.orange)
            }
            status
            Text(Format.memory(project.memory))
                .font(.system(size: 13.5, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.orange)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.orange.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .help("Stop \(project.name)")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hovering ? 0.045 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Stop \(project.name)", action: onStop)
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.id) }
        }
    }

    @ViewBuilder private var status: some View {
        switch project.status {
        case .working:
            Chip(text: "working", color: Palette.green, icon: "bolt.fill")
        case .idle(let seconds):
            Chip(text: "idle \(Format.span(seconds))", color: Color.primary.opacity(0.6), icon: "moon.fill")
        case .barelyUsed(let seconds):
            Chip(text: "up \(Format.span(seconds)), barely used", color: Color.primary.opacity(0.6), icon: "moon.fill")
        case .unknown:
            EmptyView()
        }
    }
}
