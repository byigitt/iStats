# iStats

A native macOS system monitor written in Swift and SwiftUI. Its main window has eight tabs:
Overview, CPU, Memory, Disk, Network, GPU, Battery and Projects. It also has a menu bar item with a compact dashboard, and alerts for apps that misbehave.

It samples every 2 seconds on a background queue. Work that a tab needs, like GPU client scans, `nettop` or project scanning, only runs while that tab is on screen.

![Overview](docs/screenshots/overview.png)

## Features

### Overview and detail tabs

Overview has cards for CPU, memory, GPU, disk, network and battery, plus donut charts for memory by type, memory by app and power by app.

Each detail tab shows the current value with its recent history, summary stats, the top app and a per-app list. Helper processes are grouped under their app, the same way Activity Monitor does it (Chrome helpers count as Google Chrome, shells count as the terminal that owns them).

| CPU | Memory |
| --- | --- |
| ![CPU](docs/screenshots/cpu.png) | ![Memory](docs/screenshots/memory.png) |
| **Disk** | **Network** |
| ![Disk](docs/screenshots/disk.png) | ![Network](docs/screenshots/network.png) |
| **GPU** | **Battery** |
| ![GPU](docs/screenshots/gpu.png) | ![Battery](docs/screenshots/battery.png) |

### Temperatures, fans and accessory batteries

The Battery tab shows the CPU temperature, the speed of each fan, and the battery level of connected Bluetooth accessories such as a Magic Keyboard, mouse or AirPods. The CPU tab also shows the temperature.

### 30 days of history

Every detail tab can switch from Live to 12h, 24h, 7d or 30d. The CPU and Memory tabs also list which apps used the most over that range. History is kept as 5-minute averages plus the busiest apps of each hour, in a single small file at `~/Library/Application Support/iStats/history.plist`.

![History](docs/screenshots/history.png)

### Projects

Dev servers and scripts are grouped by the git repo or project folder they run in, with their listening ports, memory, and how long they have been idle. Idle servers can be stopped from the app.

![Projects](docs/screenshots/projects.png)

### Menu bar

The menu bar item has four styles: Icon, Figure, Graph and Stacked.

| Icon | Figure | Graph | Stacked |
| --- | --- | --- | --- |
| ![Icon](docs/screenshots/menubar-icon.png) | ![Figure](docs/screenshots/menubar-figure.png) | ![Graph](docs/screenshots/menubar-graph.png) | ![Stacked](docs/screenshots/menubar-stacked.png) |

Clicking it opens a popover with the same tabs, mini charts, uptime, the busiest apps right now, and a volume slider for each app that is playing audio.

| Overview | CPU |
| --- | --- |
| ![Popover overview](docs/screenshots/popover-overview.png) | ![Popover CPU](docs/screenshots/popover-cpu.png) |

### Per-app volume

Turning an app below 100% puts a private Core Audio process tap on it. The tap mutes the app's own output and plays it back through the current output device at the chosen volume. Audio is processed live and never recorded. It needs macOS 14.2 and asks for audio access the first time.

### Quit and force quit

Right-click any app in any list to quit or force quit it, or to end one of its processes. iStats asks first and says how many processes will close.

![Quit confirmation](docs/screenshots/quit.png)

### Alerts

iStats can send a notification when:

- an app keeps the CPU busy ("Chrome is keeping the CPU busy: 70% on average for 10 minutes.")
- an app keeps using more memory ("Slack keeps using more memory: up 1.4 GB in an hour, now 3.3 GB.")
- an app keeps writing to the disk
- the Mac keeps downloading, with the app responsible for it

Each rule, its threshold and the duration can be changed in Settings.

![Settings](docs/screenshots/settings.png)

### Export as an image

The export button in the toolbar (⌘E) makes a 1200×630 card of memory, top apps, CPU or the whole dashboard, in light or dark. It can be saved as a PNG or copied.

![Export](docs/screenshots/export.png)

| Light | Dark |
| --- | --- |
| ![Memory card](docs/screenshots/share-memory-light.png) | ![Memory card dark](docs/screenshots/share-memory-dark.png) |
| ![Top apps card](docs/screenshots/share-top-apps-light.png) | ![Top apps card dark](docs/screenshots/share-top-apps-dark.png) |
| ![CPU card](docs/screenshots/share-cpu-light.png) | ![CPU card dark](docs/screenshots/share-cpu-dark.png) |
| ![Dashboard card](docs/screenshots/share-dashboard-light.png) | ![Dashboard card dark](docs/screenshots/share-dashboard-dark.png) |

### Liquid Glass

On macOS 26 the window and controls use Liquid Glass. Older systems get a vibrancy fallback.

## Requirements

- macOS 14 or later (per-app volume needs macOS 14.2, Liquid Glass needs macOS 26)
- Xcode 16 or later / Swift 5.10 or later

## Install

Download `iStats-0.0.1.zip` from the [latest release](https://github.com/byigitt/iStats/releases/latest), unzip it and move `iStats.app` to `/Applications`.

The app is signed ad hoc, so macOS quarantines it on first launch. Clear the flag once:

```bash
xattr -dr com.apple.quarantine /Applications/iStats.app
```

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
| Per-app network | `nettop` in streaming mode, only while the Network tab is open or a download alert needs an app |
| GPU | IOKit `IOAccelerator` performance statistics and per-client `accumulatedGPUTime` |
| Battery | IOKit `AppleSmartBattery`, `IOPSGetTimeRemainingEstimate` |
| CPU temperature | HID temperature sensors (`PMU tdie*`) |
| Fans | SMC keys `FNum` and `F<n>Ac` |
| Accessory batteries | IOKit `BatteryPercent`, `system_profiler SPBluetoothDataType` for AirPods |
| Per-app volume | Core Audio process taps (`CATapDescription`) and a private aggregate device |
| Projects | `PROC_PIDVNODEPATHINFO` (working directory), `PROC_PIDFDSOCKETINFO` (TCP listeners) |

"Today", "Last 7 days" and "Written today" are saved per day. Traffic that happens while iStats is closed is still counted, as long as the Mac has not rebooted in between.

## Keeping memory low

- Charts are drawn with `Canvas` instead of Swift Charts, and live history is kept in 90-sample `Float` buffers.
- App icons are read directly from each bundle's `.icns` at 64 px using ImageIO. `NSWorkspace.icon(forFile:)` pulls in IconServices, which costs about 100 MB.
- GPU client scans, `nettop`, project scanning and sensor reads only run while their tab is visible. Audio taps only exist for apps turned below 100%.
- When you close the window, its view hierarchy is released and iStats keeps running in the menu bar.
