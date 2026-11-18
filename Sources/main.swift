import Cocoa
import Darwin

// MARK: - CPU

struct Ticks { var user: UInt64; var system: UInt64; var idle: UInt64; var nice: UInt64 }

func readCPUTicks() -> Ticks? {
    var numCPU: natural_t = 0
    var info: processor_info_array_t? = nil
    var infoCount: mach_msg_type_number_t = 0
    let r = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &infoCount)
    guard r == KERN_SUCCESS, let info = info else { return nil }
    var t = Ticks(user: 0, system: 0, idle: 0, nice: 0)
    let stride = Int(CPU_STATE_MAX)
    for i in 0..<Int(numCPU) {
        t.user   += UInt64(UInt32(bitPattern: info[i * stride + Int(CPU_STATE_USER)]))
        t.system += UInt64(UInt32(bitPattern: info[i * stride + Int(CPU_STATE_SYSTEM)]))
        t.idle   += UInt64(UInt32(bitPattern: info[i * stride + Int(CPU_STATE_IDLE)]))
        t.nice   += UInt64(UInt32(bitPattern: info[i * stride + Int(CPU_STATE_NICE)]))
    }
    vm_deallocate(mach_task_self_,
                  vm_address_t(UInt(bitPattern: info)),
                  vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
    return t
}

// MARK: - Memory

struct MemInfo {
    var used: UInt64; var total: UInt64
    var app: UInt64; var wired: UInt64; var compressed: UInt64; var free: UInt64
}

func readMemory() -> MemInfo? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    let page       = UInt64(vm_kernel_page_size)
    let internal_  = UInt64(stats.internal_page_count)
    let purgeable  = UInt64(stats.purgeable_count)
    let app        = (internal_ > purgeable ? internal_ - purgeable : 0) * page
    let wired      = UInt64(stats.wire_count) * page
    let compressed = UInt64(stats.compressor_page_count) * page
    let free       = UInt64(stats.free_count) * page
    return MemInfo(used: app + wired + compressed,
                   total: ProcessInfo.processInfo.physicalMemory,
                   app: app, wired: wired, compressed: compressed, free: free)
}

// MARK: - Network  (sysctl NET_RT_IFLIST2 — 64-bit counters, all non-loopback interfaces)

struct NetBytes { var sent: UInt64; var recv: UInt64 }

func readNetworkBytes() -> NetBytes? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

    var sent: UInt64 = 0
    var recv: UInt64 = 0
    var offset = 0

    while offset + MemoryLayout<if_msghdr>.size <= len {
        let (msglen, msgtype) = buf.withUnsafeBytes { raw -> (Int, UInt8) in
            let hdr = raw.load(fromByteOffset: offset, as: if_msghdr.self)
            return (Int(hdr.ifm_msglen), hdr.ifm_type)
        }
        guard msglen > 0 else { break }

        if msgtype == RTM_IFINFO2,
           offset + MemoryLayout<if_msghdr2>.size <= len {
            let msg2 = buf.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: if_msghdr2.self)
            }
            // skip loopback (IFF_LOOPBACK = 0x8)
            if (msg2.ifm_flags & Int32(IFF_LOOPBACK)) == 0 {
                sent += msg2.ifm_data.ifi_obytes
                recv += msg2.ifm_data.ifi_ibytes
            }
        }
        offset += msglen
    }
    return NetBytes(sent: sent, recv: recv)
}

// MARK: - Formatters

func gb(_ b: UInt64) -> String {
    String(format: "%.2f GB", Double(b) / 1_073_741_824.0)
}

/// Long form for menu rows, e.g. "1.4 MB/s"
func netSpeedLong(_ bps: Double) -> String {
    switch bps {
    case ..<1_000:            return String(format: "%.0f B/s",  bps)
    case ..<1_000_000:        return String(format: "%.1f KB/s", bps / 1_000)
    case ..<1_000_000_000:    return String(format: "%.1f MB/s", bps / 1_000_000)
    default:                  return String(format: "%.2f GB/s", bps / 1_000_000_000)
    }
}

/// Compact form for the status bar, e.g. "1.4M"
func netSpeedShort(_ bps: Double) -> String {
    switch bps {
    case ..<1_000:            return String(format: "%.0fB",  bps)
    case ..<1_000_000:        return String(format: "%.0fK",  bps / 1_000)
    case ..<1_000_000_000:    return String(format: "%.1fM",  bps / 1_000_000)
    default:                  return String(format: "%.1fG",  bps / 1_000_000_000)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var rows: [String: NSMenuItem] = [:]

    var prevTicks  = readCPUTicks()
    var prevNet    = readNetworkBytes()

    var cpuPct = 0.0, userPct = 0.0, sysPct = 0.0
    var upSpeed = 0.0, downSpeed = 0.0
    var timer: Timer?

    private func addRow(_ key: String, title: String = "...") {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        menu.addItem(it)
        rows[key] = it
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CPU section
        for k in ["cpu", "user", "system", "idle"] { addRow(k) }
        menu.addItem(.separator())

        // Memory section
        for k in ["mem", "app", "wired", "comp", "free"] { addRow(k) }
        menu.addItem(.separator())

        // Network section
        addRow("net", title: "Network:")
        for k in ["up", "down"] { addRow(k) }
        menu.addItem(.separator())

        // Actions
        let am = NSMenuItem(title: "Open Activity Monitor",
                            action: #selector(openActivityMonitor),
                            keyEquivalent: "a")
        am.target = self
        menu.addItem(am)
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
        tick()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc func openActivityMonitor() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    func tick() {
        // ── CPU ──────────────────────────────────────────────────────────────
        if let now = readCPUTicks(), let p = prevTicks {
            let du = now.user   &- p.user
            let ds = now.system &- p.system
            let di = now.idle   &- p.idle
            let dn = now.nice   &- p.nice
            let total = du + ds + di + dn
            if total > 0 {
                userPct = Double(du + dn) / Double(total) * 100
                sysPct  = Double(ds)      / Double(total) * 100
                cpuPct  = userPct + sysPct
            }
            prevTicks = now
        }

        // ── Memory ───────────────────────────────────────────────────────────
        let mem    = readMemory()
        let memPct = mem.map { Double($0.used) / Double($0.total) * 100 } ?? 0

        // ── Network (bytes delta over the 1-second interval = bytes/sec) ─────
        if let now = readNetworkBytes(), let p = prevNet {
            upSpeed   = Double(now.sent >= p.sent ? now.sent - p.sent : 0)
            downSpeed = Double(now.recv >= p.recv ? now.recv - p.recv : 0)
            prevNet   = now
        }

        // ── Update menu items ─────────────────────────────────────────────────
        rows["cpu"]?.title    = String(format: "CPU: %.1f%%", cpuPct)
        rows["user"]?.title   = String(format: "    User:   %.1f%%", userPct)
        rows["system"]?.title = String(format: "    System: %.1f%%", sysPct)
        rows["idle"]?.title   = String(format: "    Idle:   %.1f%%", max(0, 100 - cpuPct))

        if let m = mem {
            rows["mem"]?.title  = "Memory: \(gb(m.used)) / \(gb(m.total))" +
                                  String(format: " (%.1f%%)", memPct)
            rows["app"]?.title  = "    App:        \(gb(m.app))"
            rows["wired"]?.title = "    Wired:      \(gb(m.wired))"
            rows["comp"]?.title  = "    Compressed: \(gb(m.compressed))"
            rows["free"]?.title  = "    Free:       \(gb(m.free))"
        }

        rows["net"]?.title  = "Network:"
        rows["up"]?.title   = "    ↑ Upload:   \(netSpeedLong(upSpeed))"
        rows["down"]?.title = "    ↓ Download: \(netSpeedLong(downSpeed))"

        // ── Status-bar button ─────────────────────────────────────────────────
        let netPart = "↑\(netSpeedShort(upSpeed)) ↓\(netSpeedShort(downSpeed))"
        let text    = String(format: "CPU %2.0f%%  MEM %2.0f%%  ", cpuPct, memPct) + netPart

        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        if cpuPct >= 85 || memPct >= 90 {
            attrs[.foregroundColor] = NSColor.systemRed
        }
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }
}

// MARK: - Entry point

let app      = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
