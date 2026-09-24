//
// Does the configure sheet's live preview stop when the sheet goes away?
//
//   swiftc -O -o out/preview-probe tools/preview-probe.swift
//   out/preview-probe ttfx.saver
//
// This matters more than it sounds. The preview is a 60 Hz engine session
// running inside System Settings — a process people leave open for hours —
// and the only thing that used to stop it was the sheet's own Done button.
// A sheet closed any other way left it running: measured at 79% of a core,
// indefinitely, which is *more* than it costs while the sheet is showing,
// because a hidden window does not coalesce the drawing away.
//
// The sheet windows are placed far outside any display, so nothing appears on
// screen and no focus is taken.
//

import AppKit
import ScreenSaver

func cpuSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
         + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

let bundlePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ttfx.saver"
guard let bundle = Bundle(path: bundlePath), bundle.load(),
      let viewClass = bundle.principalClass as? ScreenSaverView.Type else {
    FileHandle.standardError.write("cannot load \(bundlePath)\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let view = viewClass.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), isPreview: false)!
let host = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600),
                    styleMask: [.borderless], backing: .buffered, defer: false)
host.contentView = view

/// Run the real run loop — the preview is driven by a Timer, so a tick loop
/// would measure nothing — and report what it cost.
func measure(_ label: String, seconds: Double) {
    let before = cpuSeconds()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    let used = cpuSeconds() - before
    let padded = label.padding(toLength: 12, withPad: " ", startingAt: 0)
    print(padded + String(format: " %.3f s cpu / %.0f s wall   %5.1f%% of a core",
                          used, seconds, 100 * used / seconds))
}

func openSheet() -> NSWindow {
    guard let sheet = view.configureSheet else {
        FileHandle.standardError.write("the saver offered no configure sheet\n".data(using: .utf8)!)
        exit(2)
    }
    sheet.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    sheet.orderFrontRegardless()
    return sheet
}

print("bundle: \(bundlePath)")
print("")

// Closing without the Done button is the case that used to run forever:
// System Settings quit with the sheet up, the pane switched, the host ending
// the sheet itself. dismiss(_:) is deliberately never called here.
var sheet = openSheet()
print("sheet open       visible=\(sheet.isVisible)")
measure("  open:", seconds: 3)
sheet.orderOut(nil)
print("sheet closed     visible=\(sheet.isVisible)   (dismiss(_:) never called)")
measure("  closed:", seconds: 3)

// Reopening has to bring it back. A gate that stops the preview for good
// would be a worse bug than the one it fixes.
sheet = openSheet()
print("sheet reopened   visible=\(sheet.isVisible)")
measure("  reopened:", seconds: 3)
sheet.orderOut(nil)
print("sheet closed")
measure("  closed:", seconds: 3)
