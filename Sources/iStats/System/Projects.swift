import Darwin
import Foundation

enum ProjectStatus: Equatable {
    case working
    case idle(Double)
    case barelyUsed(Double)
    case unknown

    /// Idle long enough that stopping it is a reasonable suggestion.
    var isIdle: Bool {
        switch self {
        case .idle(let seconds): seconds >= 15 * 60
        case .barelyUsed: true
        default: false
        }
    }
}

struct Project: Identifiable {
    let id: String
    let name: String
    let kind: String
    let memory: Double
    let ports: [Int]
    let status: ProjectStatus
    let pids: [Int32]

    var isIdleServer: Bool { !ports.isEmpty && status.isIdle }
}

/// Finds developer processes (dev servers, watchers, scripts) and groups them by the project
/// directory they run in, along with their listening TCP ports and recent activity.
final class ProjectsProbe {
    private let home = NSHomeDirectory()
    private let uid = getuid()
    private var roots: [String: String] = [:]
    private var lastActive: [String: Double] = [:]
    private var firstSeen: [String: Double] = [:]

    private let markers = [
        "package.json", "pyproject.toml", "requirements.txt", "go.mod", "Cargo.toml", "Gemfile",
        "composer.json", "deno.json", "Package.swift", "pom.xml", "build.gradle", "mix.exs", "manage.py",
    ]
    private let ignoredExecutables: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "nu", "login", "tmux", "screen", "ssh", "sudo", "less", "man",
        "vim", "nvim", "vi", "nano", "emacs", "top", "htop", "btop", "caffeinate", "git", "watch", "tail", "sleep",
    ]
    private let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/bin/"]

    func sample(processes: [ProcessSample], grouper: AppGrouper) -> [Project] {
        struct Accumulator {
            var pids: [Int32] = []
            var memory = 0.0
            var cpu = 0.0
            var cpuTime = 0.0
            var start = Double.greatestFiniteMagnitude
            var ports = Set<Int>()
            var runtimes: [String] = []
        }

        let now = Date().timeIntervalSince1970
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        var groups: [String: Accumulator] = [:]

        for process in processes {
            let executable = grouper.info(for: process.pid).executable
            guard !executable.isEmpty,
                  !executable.contains(".app/"),
                  !systemPrefixes.contains(where: executable.hasPrefix)
            else { continue }

            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(process.pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, bsd.pbi_uid == uid else { continue }
            let command = cString(&bsd.pbi_comm)
            guard !ignoredExecutables.contains(command),
                  let directory = workingDirectory(process.pid),
                  directory.hasPrefix(home + "/"),
                  !directory.hasPrefix(home + "/Library"),
                  let root = projectRoot(for: directory)
            else { continue }

            var group = groups[root, default: Accumulator()]
            group.pids.append(process.pid)
            group.memory += process.memory
            group.cpu += process.cpu * cores
            group.cpuTime += process.cpuTime
            group.start = min(group.start, Double(bsd.pbi_start_tvsec))
            group.ports.formUnion(listeningPorts(process.pid))
            group.runtimes.append(runtime(command: command, executable: executable))
            groups[root] = group
        }

        var projects: [Project] = []
        for (root, group) in groups {
            if firstSeen[root] == nil { firstSeen[root] = now }
            let working = group.cpu >= 3
            if working { lastActive[root] = now }

            let status: ProjectStatus
            let age = now - group.start
            if working {
                status = .working
            } else if let active = lastActive[root] {
                status = now - active >= 5 * 60 ? .idle(now - active) : .unknown
            } else if age >= 3600, group.cpuTime / age < 0.01 {
                status = .barelyUsed(age)
            } else if let seen = firstSeen[root], now - seen >= 5 * 60 {
                status = .idle(now - seen)
            } else {
                status = .unknown
            }

            let kind = group.pids.count == 1 ? group.runtimes[0] : "\(group.pids.count) processes"
            projects.append(Project(
                id: root,
                name: (root as NSString).lastPathComponent,
                kind: kind,
                memory: group.memory,
                ports: group.ports.sorted(),
                status: status,
                pids: group.pids
            ))
        }

        let live = Set(groups.keys)
        lastActive = lastActive.filter { live.contains($0.key) }
        firstSeen = firstSeen.filter { live.contains($0.key) }
        return projects.sorted { $0.memory > $1.memory }
    }

    private func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(&info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Nearest enclosing git repository, else the nearest directory with a project manifest.
    private func projectRoot(for directory: String) -> String? {
        if let cached = roots[directory] { return cached.isEmpty ? nil : cached }
        let files = FileManager.default
        var current = directory
        var repository: String?
        var manifest: String?
        while current.count > home.count {
            if repository == nil, files.fileExists(atPath: current + "/.git") { repository = current }
            if manifest == nil, markers.contains(where: { files.fileExists(atPath: current + "/" + $0) }) { manifest = current }
            if repository != nil { break }
            current = (current as NSString).deletingLastPathComponent
        }
        let root = repository ?? manifest
        if roots.count > 512 { roots.removeAll() }
        roots[directory] = root ?? ""
        return root
    }

    private func listeningPorts(_ pid: Int32) -> Set<Int> {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bytes)
        guard filled > 0 else { return [] }

        var ports = Set<Int>()
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for descriptor in descriptors.prefix(Int(filled) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize,
                  socket.psi.soi_kind == SOCKINFO_TCP
            else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            if tcp.tcpsi_state == TSI_S_LISTEN {
                ports.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))))
            }
        }
        return ports
    }

    private func runtime(command: String, executable: String) -> String {
        let name = command.lowercased()
        if name.hasPrefix("python") { return "python" }
        if name.hasPrefix("node") { return "node" }
        if name.hasPrefix("ruby") { return "ruby" }
        if name.hasPrefix("php") { return "php" }
        if name.hasPrefix("beam") { return "elixir" }
        if name == "java" { return "java" }
        if executable.contains("/go-build") || name == "go" { return "go" }
        return command
    }
}
