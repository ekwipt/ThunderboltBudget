# Thunderbolt Budget ⚡️

A macOS utility for DITs, video editors and power users that maps and monitors Thunderbolt / USB4
bandwidth in real time: which devices hang off which physical port, how much of each port's 40 Gbps
they are using, and when a port is about to bottleneck.

**Requires an Apple silicon Mac** (M1 or later). Intel Macs are not supported.

## Why this exists
Each Thunderbolt controller on a Mac has a hard limit of **40 Gbps**. When cascading NVMe RAID arrays,
10 GbE adapters and 4K/5K displays it is easy to silently saturate a port, causing dropped frames
or slow offloads. Thunderbolt Budget shows where each device is plugged in and charts live usage.

## Features
- **Physical port mapping** — shows which devices are attached to which Thunderbolt port (named by
  chassis position on supported models, otherwise "Thunderbolt Port N").
- **Live throughput** — measured disk and network traffic per device, plus a 60 s chart of the bus
  total (display bandwidth is estimated from resolution and refresh rate).
- **Bottleneck alerts** — a local notification when total throughput crosses a threshold you set.
- **Menu bar view** — per-port live rates and a throughput sparkline without opening the window.
- **Settings** — alert threshold, alerts on/off, refresh rate, launch at login.

## How it works
Everything is read natively and read-only, with no subprocesses, so it runs inside the App Sandbox:

| Data | Source |
|---|---|
| Thunderbolt switches, ports, link speeds | IOKit registry (`IOThunderbolt*`) |
| USB devices, BSD names, display EDID | IOKit registry walk |
| Display resolution / refresh | CoreGraphics |
| Disk throughput | IOKit `IOBlockStorageDriver` statistics |
| Network throughput | `sysctl` interface counters |

A full hardware scan takes well under a second.

## Known limitations
- Chassis port names ("Left Back Port", …) are only defined for some Mac models; others show
  "Thunderbolt Port N".
- Network byte counters are exposed by macOS as 32-bit values, so rates are computed from deltas
  with wrap handling (accurate up to roughly 17 Gbps per interface at a 2 s refresh).
- Thunderbolt firmware version strings are not shown.

## Building
1. Open `ThunderboltBudget.xcodeproj` in a current Xcode.
2. Select **My Mac** (Apple silicon) and press **⌘R**, or **Product ▸ Archive** to distribute.
3. Tests: **⌘U** (Swift Testing).
