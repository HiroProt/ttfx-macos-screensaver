//
// Drive the real ttfx.saver through its real lifecycle and measure what it
// costs, without a screen saver session and without borrowing the display.
//
//   swiftc -O -o out/saver-probe tools/saver-probe.swift
//   out/saver-probe ttfx.saver --cycles 400
//
// What it answers, which staring at the code does not:
//
//   * does memory grow per effect cycle — the engine session is a Rust
//     allocation freed through ttfx_session_free, and a cycle that leaks it
//     leaks the whole canvas
//   * does the view stop working when its window stops being visible, which
//     is how a dismissal presents itself to the view
//   * does parking actually drop the tick rate, rather than only claiming to
//   * what a frame costs end to end, engine plus glyph rendering
//
// Drawing is forced into a bitmap with cacheDisplay(in:to:), not left to
// displayIfNeeded(). animateOneFrame only marks the view dirty; there is no
// run loop to service that, and for a window placed off every display AppKit
// may skip the draw entirely — which moved the measured frame cost by 40x
// between two runs of this probe before it drew into a bitmap instead.
//
// Cost is reported as CPU time out of getrusage, not wall time: the tick loop
// here is as fast as the machine allows, so wall time would measure this
// harness rather than the saver. Per-tick CPU is the number that transfers.
//
// Every tick runs inside its own autorelease pool, because the host's run
// loop drains one per iteration and this loop has no run loop. Without it the
// probe reports a steady ~57 KB per effect cycle of "growth" that is entirely
// the probe's own undrained pool — a broken harness reading as a leak.
//
// The window is placed far outside any display and the process runs with
// activation policy .prohibited, so it has no Dock presence, never activates,
// and nothing appears on screen. It still counts as visible to AppKit, which
// is exactly the state being measured.
//

import AppKit
import ScreenSaver

// MARK: - measurement

/// Physical footprint — the number macOS itself charges a process, and the one
/// Activity Monitor shows. Deliberately not `resident_size`: that counts every
/// mapped page a process has touched, including framework text, so it climbs
/// as new code paths run and keeps climbing as new effects are exercised.
/// Reading it made an earlier version of this probe report 45 MB growing to
/// 171 MB with no leak anywhere — the memory was Swift and AppKit being paged
/// in, and `heap` put the real footprint at 34 MB with a 3 MB malloc heap.
func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

func cpuSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return user + sys
}

func mb(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

// MARK: - arguments

var bundlePath = "ttfx.saver"
var cycles = 200
// The canvas the view is given. Worth varying: the grid targets a column
// count, so columns barely move with resolution but rows scale with height,
// and a tall display puts far more cells on the canvas than a wide one.
var size = NSSize(width: 1728, height: 1117)
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--cycles": cycles = Int(args.first ?? "") ?? cycles; if !args.isEmpty { args.removeFirst() }
    case "--size":
        let parts = (args.first ?? "").split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
        if !args.isEmpty { args.removeFirst() }
    default: bundlePath = arg
    }
}

// MARK: - load the shipped bundle

guard let bundle = Bundle(path: (bundlePath as NSString).expandingTildeInPath) else {
    FileHandle.standardError.write("no bundle at \(bundlePath)\n".data(using: .utf8)!)
    exit(2)
}
guard bundle.load(), let viewClass = bundle.principalClass as? ScreenSaverView.Type else {
    FileHandle.standardError.write("\(bundlePath) did not load — a signature or Gatekeeper problem shows up here first\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

guard let view = viewClass.init(frame: NSRect(origin: .zero, size: size), isPreview: false) else {
    FileHandle.standardError.write("the principal class refused to initialise\n".data(using: .utf8)!)
    exit(2)
}

// Far outside any display: visible to AppKit, on nobody's screen.
let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = view
window.orderFrontRegardless()

print("bundle:  \(bundlePath)")
print("class:   \(viewClass)")
print("canvas:  \(Int(size.width))x\(Int(size.height))")
print("visible: \(window.isVisible)")
print("")

// MARK: - phase 1: on screen, many effect cycles

view.startAnimation()

// Let it settle so the first allocation of fonts and kern tables is not
// counted as growth.
for _ in 0..<200 { autoreleasepool { view.animateOneFrame() } }
// The bitmap is allocated before the baseline is taken: at this canvas it is
// 7.7 MB, and taking the baseline first would charge the probe's own buffer to
// the saver as growth.
let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in: view.bounds, to: rep)

let baseline = footprintBytes()
let cpu0 = cpuSeconds()

var ticks = 0
var peak = baseline
// A cycle is one effect run plus its hold. Ticking straight through is the
// point: this compresses hours of screen saver into seconds, which is the
// only way a per-cycle leak becomes visible at all.
let ticksPerCycle = 400
for _ in 0..<cycles {
    for _ in 0..<ticksPerCycle {
        autoreleasepool {
            view.animateOneFrame()
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        ticks += 1
    }
    peak = max(peak, footprintBytes())
}
let cpu1 = cpuSeconds()
let afterRun = footprintBytes()

print("running, \(cycles) cycles / \(ticks) ticks")
print("  footprint base     \(mb(baseline))")
print("  footprint peak     \(mb(peak))")
print("  footprint after    \(mb(afterRun))")
let growth = Double(afterRun) - Double(baseline)
print(String(format: "  growth             %+.1f KB over %d ticks (%+.1f bytes/tick)",
             growth / 1024, ticks, growth / Double(ticks)))
print(String(format: "  cpu                %.3f s total, %.3f ms/tick",
             cpu1 - cpu0, (cpu1 - cpu0) * 1000 / Double(ticks)))
print("  tick interval      \(view.animationTimeInterval) s")
print("")

// MARK: - phase 2: the window stops being visible

// This is what a dismissal looks like from inside the view: the window is no
// longer on screen, and nothing has called stopAnimation. The saver is
// expected to notice by itself and stop doing work.
window.orderOut(nil)
print("dismissed (window ordered out, stopAnimation NOT called)")
print("  visible            \(window.isVisible)")

// The visibility verdict is cached for a quarter second, so give the gate a
// chance to be asked again rather than reading the cached answer.
let settle = Date().addingTimeInterval(0.6)
while Date() < settle { autoreleasepool { view.animateOneFrame() } }

let cpu2 = cpuSeconds()
let beforeIdle = footprintBytes()
var idleTicks = 0
// displayIfNeeded stays in the parked loop on purpose: if parking left the
// view marked dirty, this is where that would cost something.
for _ in 0..<200_000 {
    autoreleasepool { view.animateOneFrame(); view.displayIfNeeded() }
    idleTicks += 1
}
let cpu3 = cpuSeconds()
// Freeing the engine session hands pages back to the allocator, which is not
// the same as handing them back to the kernel — so ask it to. Without this,
// "released" is measuring malloc's retention policy, not the saver's.
malloc_zone_pressure_relief(nil, 0)
let afterIdle = footprintBytes()

print("  tick interval      \(view.animationTimeInterval) s  (parked = 1.0)")
print("  footprint          \(mb(beforeIdle)) → \(mb(afterIdle))")
print(String(format: "  cpu                %.3f s over %d parked ticks (%.4f ms/tick)",
             cpu3 - cpu2, idleTicks, (cpu3 - cpu2) * 1000 / Double(idleTicks)))
let released = Double(afterRun) - Double(beforeIdle)
print(String(format: "  released on park   %+.1f KB", released / 1024))
print("")

// MARK: - phase 3: stopAnimation, then start again

view.stopAnimation()
let afterStop = footprintBytes()
print("stopAnimation")
print("  tick interval      \(view.animationTimeInterval) s")
print("  footprint          \(mb(afterStop))")
print("")

// A leak across start/stop is a different leak from one across effect cycles:
// a screen saver that runs twenty times a day hits this path twenty times and
// the effect-cycle path thousands of times. One run of each would not show it.
// Reported as a distribution, not a per-cycle growth rate. The footprint
// tracks whatever effect is live, and effects differ by tens of megabytes, so
// a rate fitted to twenty samples is reading a trend off noise: an earlier
// version of this probe did exactly that and called +2.3 MB per start/stop a
// leak. Over enough cycles the series goes down as often as up.
let restarts = 60
var series: [UInt64] = []
for _ in 0..<restarts {
    window.orderFrontRegardless()
    view.startAnimation()
    for _ in 0..<300 { autoreleasepool { view.animateOneFrame(); view.cacheDisplay(in: view.bounds, to: rep) } }
    view.stopAnimation()
    window.orderOut(nil)
    for _ in 0..<20 { autoreleasepool { view.animateOneFrame() } }
    malloc_zone_pressure_relief(nil, 0)
    series.append(footprintBytes())
}
let firstTen = series.prefix(10).reduce(0.0) { $0 + Double($1) } / 10
let lastTen = series.suffix(10).reduce(0.0) { $0 + Double($1) } / 10
print("\(restarts) start/stop cycles, footprint after each")
print("  tick interval      \(view.animationTimeInterval) s  (parked = 1.0)")
print("  min / max          \(mb(series.min()!)) / \(mb(series.max()!))")
print("  first 10 mean      \(mb(UInt64(firstTen)))")
print("  last 10 mean       \(mb(UInt64(lastTen)))")
print(String(format: "  drift              %+.1f MB across %d cycles",
             (lastTen - firstTen) / 1_048_576, restarts))
print("")

malloc_zone_pressure_relief(nil, 0)
let settled = footprintBytes()
print("")
print(String(format: "net over the whole probe: %+.1f KB", (Double(settled) - Double(baseline)) / 1024))
