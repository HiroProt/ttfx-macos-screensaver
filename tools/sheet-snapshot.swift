//
// Render the configure sheet to a PNG without putting it on anyone's screen.
//
//   swiftc -O -o out/sheet-snapshot tools/sheet-snapshot.swift
//   out/sheet-snapshot ttfx.saver out/sheet.png [--appearance dark|light]
//
// The sheet is built by the real bundle through the real `configureSheet`
// entry point System Settings uses. The window is placed far outside every
// display and the process runs with activation policy .prohibited: no focus
// is taken and nothing appears on screen.
//
// Read it as a layout check, not a screenshot. The PDF path draws text
// fields, custom views and the live preview faithfully, but bezeled controls
// — push buttons, sliders, popups, the table rows — do not all draw into it
// and come out missing. Positions, wording, colour and alignment are
// trustworthy here; "that control is gone" is not.
//

import AppKit
import ScreenSaver

var bundlePath = "ttfx.saver"
var outPath = "out/sheet.png"
var dark = true
var args = Array(CommandLine.arguments.dropFirst())
var positional: [String] = []
while let a = args.first {
    args.removeFirst()
    if a == "--appearance" {
        dark = (args.first ?? "dark") == "dark"
        if !args.isEmpty { args.removeFirst() }
    } else {
        positional.append(a)
    }
}
if positional.count > 0 { bundlePath = positional[0] }
if positional.count > 1 { outPath = positional[1] }

guard let bundle = Bundle(path: bundlePath), bundle.load(),
      let viewClass = bundle.principalClass as? ScreenSaverView.Type else {
    FileHandle.standardError.write("cannot load \(bundlePath)\n".data(using: .utf8)!)
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

let view = viewClass.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), isPreview: false)!
let host = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600),
                    styleMask: [.borderless], backing: .buffered, defer: false)
host.contentView = view

guard let sheet = view.configureSheet, let content = sheet.contentView else {
    FileHandle.standardError.write("no configure sheet\n".data(using: .utf8)!)
    exit(2)
}
sheet.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
sheet.setFrameOrigin(NSPoint(x: -30000, y: -30000))
sheet.orderFrontRegardless()

// Let the live preview produce a frame, so the shot is not a black rectangle
// where the interesting half of the sheet is.
RunLoop.main.run(until: Date().addingTimeInterval(1.2))
content.layoutSubtreeIfNeeded()
content.displayIfNeeded()

// Rasterise the view's PDF rather than cacheDisplay(in:to:).
//
// AppKit controls are layer-backed and cacheDisplay does not composite them:
// the first version of this tool produced a sheet containing the effect list
// and the live preview with every label, slider, popup and button missing,
// which reads as a broken layout and is really a broken capture. The PDF path
// is the printing path, and controls draw into it.
//
// CGWindowListCreateImage would capture the real backing store, but it is
// unavailable from macOS 27 and its replacement wants Screen Recording
// permission for a tool that should need none.
let scale: CGFloat = 2
let bounds = content.bounds
let pdf = content.dataWithPDF(inside: bounds)
guard let image = NSImage(data: pdf),
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(bounds.width * scale),
                                 pixelsHigh: Int(bounds.height * scale),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)
else { exit(3) }
rep.size = bounds.size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// Without an explicit fill this is controls floating on transparency, which
// hides every label the moment the PNG is viewed on anything dark.
NSColor.windowBackgroundColor.setFill()
bounds.fill()
image.draw(in: bounds)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
