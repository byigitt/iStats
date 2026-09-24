# iStats

A native macOS system monitor written in Swift and SwiftUI. Its main window has eight tabs:
Overview, CPU, Memory, Disk, Network, GPU, Battery and Projects. It also has a menu bar item with a compact dashboard, and it can notify you when an app keeps the CPU busy.

The app is built to stay small. With the window open it uses about 40–50 MB. It samples every 2 seconds on a background queue, and when you are not looking at a tab, the sampling that tab needs stops.

## Features

- **Overview**: cards for CPU, memory, GPU, disk, network and battery, plus donut charts for memory by type, memory by app and power by app.
- **CPU / Memory / Disk / Network / GPU / Battery**: a current value with its recent history, summary stats, the top app, and a per-app list. Helper processes are grouped under their app, the same way Activity Monitor does it (Chrome helpers count as Google Chrome, shells count as the terminal that owns them).
- **Projects**: dev servers and scripts grouped by the git repo or project folder they run in, with their listening ports, memory, and how long they have been idle. Idle servers can be stopped from the app.
- **Menu bar**: a pulse icon with the current CPU %. Clicking it opens a popover with the same tabs, mini charts, uptime, and the busiest apps right now.
- **Notifications**: for example, "Chrome is keeping the CPU busy: 70% on average for 10 minutes." You can change the threshold and duration in Settings.
- **Liquid Glass**: on macOS 26 the window and controls use Liquid Glass. Older systems get a vibrancy fallback.

## Requirements

- macOS 14 or later (Liquid Glass needs macOS 26)
- Xcode 16 or later / Swift 5.10 or later

## Build

```bash
./scripts/build-app.sh      # produces build/iStats.app
open build/iStats.app
```

To regenerate the app icon, run `swift scripts/make-icon.swift .`.

## Where the numbers come from

| Metric | Source |
| --- | --- |
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)`, `getloadavg`, `hw.perflevel*` |
| Memory | `host_statistics64(HOST_VM_INFO64)`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level` |
| Per-process CPU, memory, disk writes, energy | `proc_pid_rusage(RUSAGE_INFO_V6)` |
| App grouping | `responsibility_get_pid_responsible_for_pid`, `proc_pidpath` |
| Disk throughput | IOKit `IOBlockStorageDriver` statistics |
| Network throughput | `sysctl(NET_RT_IFLIST2)` 64-bit counters on `en*` interfaces |
| Per-app network | `nettop` in streaming mode, only while the Network tab is open |
| GPU | IOKit `IOAccelerator` performance statistics and per-client `accumulatedGPUTime` |
| Battery | IOKit `AppleSmartBattery`, `IOPSGetTimeRemainingEstimate` |
| Projects | `PROC_PIDVNODEPATHINFO` (working directory), `PROC_PIDFDSOCKETINFO` (TCP listeners) |

"Today", "Last 7 days" and "Written today" are saved per day. Traffic that happens while iStats is closed is still counted, as long as the Mac has not rebooted in between.

## Keeping memory low

- Charts are drawn with `Canvas` instead of Swift Charts, and history is kept in 90-sample `Float` buffers.
- App icons are read directly from each bundle's `.icns` at 64 px using ImageIO. `NSWorkspace.icon(forFile:)` pulls in IconServices, which costs about 100 MB.
- GPU client scans, `nettop` and project scanning only run while their tab is visible.
- When you close the window, its view hierarchy is released and iStats keeps running in the menu bar.
