//
// The macOS screensaver face of ttfx: the Rust engine is linked in as a
// static library (saver/ttfx.h -> src/capi.rs) and pulled for one frame per
// animation tick, so this file is only a cell-grid renderer — a black canvas,
// a monospace font, and an SGR interpreter for the engine's frame strings.
//
// Geometry matches Omarchy's screensaver: canvas fills the screen, logo
// centered, a random effect per cycle with a short hold on the final frame.
//
// TTFXRenderer holds one effect run and is shared by the screensaver itself
// and the live effect previews in the configure sheet.
//

import ScreenSaver

// MARK: - Settings

/// Every knob, read fresh from the module defaults so configure-sheet edits
/// apply at the next effect cycle without restarting the saver.
enum TTFXSettings {
    static let moduleName = "gg.ka.ttfx"
    /// One shared instance: ScreenSaverDefaults (unlike UserDefaults) only
    /// persists what was set on the instance you call synchronize() on.
    static let defaults: ScreenSaverDefaults? =
        ScreenSaverDefaults(forModuleWithName: moduleName)

    static let effectNames: [String] =
        String(cString: ttfx_effect_list()).split(separator: ",").map(String.init)

    /// Re-read the backing store. The configure sheet runs inside System
    /// Settings while the saver runs inside legacyScreenSaver — different
    /// long-lived processes, so without this the running saver keeps serving
    /// the values its instance cached at launch. UserDefaults.synchronize()
    /// alone does not pull another process's writes; invalidating the
    /// ByHost preference domain (where ScreenSaverDefaults lives) does.
    /// Call once per effect cycle, never per frame.
    static func refresh() {
        CFPreferencesSynchronize(moduleName as CFString,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesCurrentHost)
        defaults?.synchronize()
    }

    /// The art scales with the screen: cell size is chosen so the canvas is
    /// about this many columns wide at any resolution. "Columns" narrows or
    /// widens that target (fewer columns = bigger art); "FontSize" (points)
    /// bypasses it entirely for scripted setups.
    static var targetColumns: CGFloat {
        let c = defaults?.double(forKey: "Columns") ?? 0
        return c >= 40 && c <= 300 ? CGFloat(c) : 110
    }

    /// Seconds the finished text stays on screen before the next effect.
    static var holdSeconds: Double {
        guard let d = defaults, d.object(forKey: "HoldSeconds") != nil else { return 2 }
        return min(max(d.double(forKey: "HoldSeconds"), 0), 30)
    }

    /// Animation ticks per second. Each tick advances the effect exactly one
    /// frame, so this is both smoothness and animation speed — Omarchy's
    /// screensaver runs tte at 120. The display's refresh rate is the real
    /// ceiling: asking for 120 on a 60 Hz panel just gets 60.
    ///
    /// Reads the module defaults, which inside the sandboxed host means the
    /// container copy, not `~/Library/Preferences/ByHost`. Writing that outer
    /// path with `defaults -currentHost` changes nothing the saver ever sees.
    static var frameRate: Int {
        let f = defaults?.integer(forKey: "FrameRate") ?? 0
        return (15...240).contains(f) ? f : 60
    }

    /// What to do with SGR color already in the logo file — the difference
    /// between plain ASCII art and ANSI art. 0 lets the effect own every
    /// color, 1 keeps the art's own color wherever the effect is not itself
    /// coloring, 2 always keeps it.
    static var colorMode: UInt8 {
        switch defaults?.string(forKey: "ArtColors") {
        case "dynamic": return 1
        case "always": return 2
        default: return 0
        }
    }

    /// The effects the shuffle draws from. An empty or unset list means all
    /// of them — the saver must never have nothing to play.
    static var enabledEffects: [String] {
        if let names = defaults?.stringArray(forKey: "Effects") {
            let valid = names.filter { effectNames.contains($0) }
            if !valid.isEmpty { return valid }
        }
        // Migration: the first sheet shipped a single pinned "Effect".
        if let one = defaults?.string(forKey: "Effect"), effectNames.contains(one) {
            return [one]
        }
        return effectNames
    }

    static func setEnabledEffects(_ names: [String]) {
        // All selected is stored as "no restriction" so effects added by a
        // future build are picked up instead of silently excluded.
        if names.count == effectNames.count || names.isEmpty {
            defaults?.removeObject(forKey: "Effects")
        } else {
            defaults?.set(names, forKey: "Effects")
        }
        defaults?.removeObject(forKey: "Effect")
        defaults?.synchronize()
    }

    /// Precedence: fresh read of LogoPath (picks up edits when the
    /// screensaver host can reach the file) → LogoText, the content snapshot
    /// the configure sheet stores at pick time (immune to the host's
    /// sandbox) → the bundled logo.
    static func loadLogo() -> String {
        if let path = defaults?.string(forKey: "LogoPath") {
            let expanded = (path as NSString).expandingTildeInPath
            if let text = try? String(contentsOfFile: expanded, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return text
            }
        }
        if let text = defaults?.string(forKey: "LogoText"),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return text
        }
        if let url = Bundle(for: TTFXSaverView.self).url(forResource: "logo", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8)
        {
            return text
        }
        return "t t f x"
    }

    /// Cell metrics for a canvas of the given width.
    static func metrics(forWidth width: CGFloat)
        -> (font: NSFont, bold: NSFont, cellW: CGFloat, cellH: CGFloat)
    {
        // Cell width per point of font size (Menlo advances ~0.6 em), so the
        // point size actually lands targetColumns cells across the width.
        let probe = NSFont(name: "Menlo", size: 100)
            ?? NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        let advancePerPoint = ("M" as NSString)
            .size(withAttributes: [.font: probe]).width / 100
        var size = width / (targetColumns * advancePerPoint)
        if let custom = defaults?.double(forKey: "FontSize"), custom > 0 {
            size = CGFloat(custom)
        }
        size = min(max(size, 3), 100)
        let base = NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        return (base, bold,
                ("M" as NSString).size(withAttributes: [.font: base]).width,
                ceil(base.ascender - base.descender + base.leading))
    }
}

// MARK: - Renderer

/// One effect run over one canvas: owns the engine session, turns each frame
/// into styled rows, and draws them centered. Used full-screen by the saver
/// and thumbnail-sized by the configure sheet's preview.
final class TTFXRenderer {
    private var session: OpaquePointer?
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var cellWidth: CGFloat = 1
    private var cellHeight: CGFloat = 1
    private var frameRows: [NSAttributedString] = []

    private(set) var cols = 0
    private(set) var rows = 0

    deinit { end() }

    func start(effect: String, logo: String, size: NSSize, frameRate: Int) {
        end(clearFrame: true)
        (font, boldFont, cellWidth, cellHeight) = TTFXSettings.metrics(forWidth: size.width)
        cols = max(8, Int(size.width / cellWidth))
        rows = max(4, Int(size.height / cellHeight))
        session = ttfx_session_new(effect, logo, Int64(cols), Int64(rows),
                                   Int64(frameRate), UInt64.random(in: .min ... .max),
                                   TTFXSettings.colorMode)
    }

    func end(clearFrame: Bool = false) {
        if let s = session {
            ttfx_session_free(s)
            session = nil
        }
        if clearFrame {
            frameRows.removeAll(keepingCapacity: false)
        }
    }

    var isRunning: Bool { session != nil }

    /// Advance one frame. False means the effect finished.
    @discardableResult
    func advance() -> Bool {
        guard let s = session, let frame = ttfx_session_next_frame(s) else { return false }
        frameRows = Self.parse(frame: String(cString: frame), font: font, boldFont: boldFont)
        return true
    }

    /// True when the canvas no longer matches the view it draws into.
    func gridStale(for size: NSSize) -> Bool {
        cols != max(8, Int(size.width / cellWidth)) || rows != max(4, Int(size.height / cellHeight))
    }

    func draw(in bounds: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard !frameRows.isEmpty else { return }
        let x0 = (bounds.width - CGFloat(cols) * cellWidth) / 2
        let yTop = (bounds.height + CGFloat(rows) * cellHeight) / 2
        for (r, row) in frameRows.enumerated() {
            row.draw(at: NSPoint(x: x0, y: yTop - CGFloat(r + 1) * cellHeight))
        }
    }

    // MARK: SGR interpretation

    private struct SGRState {
        var fg: NSColor?
        var bg: NSColor?
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
    }

    /// Frame rows come top-first; SGR state persists across rows like a real
    /// terminal, so it threads through the whole frame.
    private static func parse(frame: String, font: NSFont, boldFont: NSFont) -> [NSAttributedString] {
        var state = SGRState()
        return frame
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { row(of: $0, state: &state, font: font, boldFont: boldFont) }
    }

    private static func row(
        of line: Substring, state: inout SGRState, font: NSFont, boldFont: NSFont
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var run = String()

        func flush() {
            guard !run.isEmpty else { return }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: state.bold ? boldFont : font,
                .foregroundColor: state.fg ?? NSColor.white,
            ]
            if let bg = state.bg { attrs[.backgroundColor] = bg }
            if state.italic { attrs[.obliqueness] = 0.2 }
            if state.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if state.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: run, attributes: attrs))
            run.removeAll(keepingCapacity: true)
        }

        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\u{1B}", line.index(after: i) < line.endIndex,
               line[line.index(after: i)] == "["
            {
                // CSI ... m — anything else ending in another final byte is
                // not part of a frame string; skip it unstyled.
                var j = line.index(i, offsetBy: 2)
                var params = String()
                while j < line.endIndex, line[j] == ";" || line[j].isNumber {
                    params.append(line[j])
                    j = line.index(after: j)
                }
                if j < line.endIndex, line[j] == "m" {
                    flush()
                    apply(params: params, to: &state)
                }
                i = j < line.endIndex ? line.index(after: j) : j
            } else {
                run.append(ch)
                i = line.index(after: i)
            }
        }
        flush()
        return out
    }

    private static func apply(params: String, to state: inout SGRState) {
        let codes = params.isEmpty
            ? [0]
            : params.split(separator: ";", omittingEmptySubsequences: false)
                .map { Int($0) ?? 0 }
        var i = 0
        while i < codes.count {
            switch codes[i] {
            case 0: state = SGRState()
            case 1: state.bold = true
            case 3: state.italic = true
            case 4: state.underline = true
            case 9: state.strikethrough = true
            case 22: state.bold = false
            case 23: state.italic = false
            case 24: state.underline = false
            case 29: state.strikethrough = false
            case 39: state.fg = nil
            case 49: state.bg = nil
            case 38, 48:
                let isFg = codes[i] == 38
                var color: NSColor?
                if i + 4 < codes.count, codes[i + 1] == 2 {
                    color = NSColor(
                        srgbRed: CGFloat(codes[i + 2].clamped255) / 255,
                        green: CGFloat(codes[i + 3].clamped255) / 255,
                        blue: CGFloat(codes[i + 4].clamped255) / 255,
                        alpha: 1)
                    i += 4
                } else if i + 2 < codes.count, codes[i + 1] == 5 {
                    color = xterm256Color(codes[i + 2].clamped255)
                    i += 2
                }
                if let color {
                    if isFg { state.fg = color } else { state.bg = color }
                }
            default:
                break
            }
            i += 1
        }
    }

    private static func xterm256Color(_ n: Int) -> NSColor {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                    blue: CGFloat(b) / 255, alpha: 1)
        }
        switch n {
        case 0...15:
            // Standard + bright ANSI, xterm defaults.
            let table = [
                (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
                (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
                (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
                (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
            ][n]
            return rgb(table.0, table.1, table.2)
        case 16...231:
            let levels = [0, 95, 135, 175, 215, 255]
            let c = n - 16
            return rgb(levels[c / 36], levels[(c / 6) % 6], levels[c % 6])
        default:
            let gray = 8 + 10 * (n - 232)
            return rgb(gray, gray, gray)
        }
    }
}

private extension Int {
    var clamped255: Int { Swift.min(Swift.max(self, 0), 255) }
}

// MARK: - The screensaver

@objc(TTFXSaverView)
public final class TTFXSaverView: ScreenSaverView {
    private let renderer = TTFXRenderer()
    private var logo = TTFXSettings.loadLogo()
    private var holdUntil: TimeInterval?
    private var lastEffect = ""
    private var fps = TTFXSettings.frameRate
    private var isParked = false
    private var lastOnScreenCheck = -Double.infinity
    private var lastOnScreenResult = false
    private var hasSeenHostThisRun = false

    /// Keep checking for a resurfaced host without letting a stale host wake
    /// the CPU at animation frequency. One second is also the maximum delay
    /// before a newly shown instance resumes.
    private static let parkedInterval: TimeInterval = 1
    /// Tick rate while holding the finished frame. See the hold branch.
    private static let holdTickInterval: TimeInterval = 0.1
    private static let engineBundleIdentifier = "com.apple.ScreenSaver.Engine"
    private static let wallpaperBundleIdentifier = "com.apple.wallpaper.agent"

    private var frameInterval: TimeInterval { 1.0 / Double(fps) }

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = frameInterval
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    /// Parking leaves the tick rate at `parkedInterval` and the cached verdict
    /// at "off screen", and the host builds its timer from whatever the
    /// property holds when animation starts. A restarted instance would
    /// otherwise tick at 1 Hz against that stale verdict — a second of black
    /// before anything moves — so undo the parked state up front.
    ///
    /// `hasSeenHostThisRun` resets here too: a view instance can outlive the
    /// launch that created it and be started again through a different host,
    /// so recognizing one host must not make this instance assume every later
    /// launch is recognizable.
    public override func startAnimation() {
        isParked = false
        hasSeenHostThisRun = false
        lastOnScreenCheck = -Double.infinity
        animationTimeInterval = frameInterval
        super.startAnimation()
    }

    public override func stopAnimation() {
        park(now: ProcessInfo.processInfo.systemUptime)
        super.stopAnimation()
    }

    private func beginSession() {
        // Re-read the knobs so configure-sheet changes land on this cycle.
        TTFXSettings.refresh()
        logo = TTFXSettings.loadLogo()
        fps = TTFXSettings.frameRate
        animationTimeInterval = frameInterval
        holdUntil = nil
        let pool = TTFXSettings.enabledEffects
        var pick = pool.randomElement() ?? "beams"
        while pool.count > 1 && pick == lastEffect {
            pick = pool.randomElement()!
        }
        lastEffect = pick
        renderer.start(effect: pick, logo: logo, size: bounds.size, frameRate: fps)
    }

    /// `window.isVisible` remains true after macOS 14+ dismisses some legacy
    /// screen savers, while our own remote view's window is absent from
    /// WindowServer's on-screen list. Full-screen playback does, however, have
    /// either the legacy ScreenSaverEngine controller or WallpaperAgent's
    /// public, on-screen compositor surface. The latter matters for launches
    /// from System Settings and other modern entry points, which need not keep
    /// ScreenSaverEngine alive. Embedded previews use ScreenSaverView's
    /// explicit preview state. The result is cached for a quarter second while
    /// active and a full second while parked.
    ///
    /// Until one of those signals has been seen during this animation run, an
    /// unrecognized signal means "keep animating", not "park".
    ///
    /// Neither direction is free. Wrongly deciding "on screen" is precisely the
    /// bug this check exists to fix: a dismissed instance renders where nobody
    /// can see it and spends CPU and battery for as long as it lingers — which
    /// can be the whole life of the host process. Nothing here reliably ends it:
    /// stopAnimation was not called on any measured dismissal, and startAnimation
    /// clears the parked state rather than the renderer, so it re-arms the
    /// fail-open rather than closing it. What still makes this the direction to
    /// prefer is that the screen saver keeps working and the cost stays
    /// observable from outside — it shows up in Activity Monitor, against a
    /// process that can be diagnosed and killed. Wrongly deciding "off screen"
    /// leaves a black screen with no way back and nothing to diagnose from. An
    /// unfamiliar host — a future launch path, a renamed agent — has to fail
    /// toward the observable one.
    ///
    /// The race this covers is a compositor surface that reaches WindowServer
    /// some ticks after the view's own window is already visible. It does not
    /// cover the view's window being absent or not yet ordered in: that returns
    /// false above, before the fail-open applies, and parks. Parking is the
    /// right answer there, because an invisible window is also exactly how
    /// dismissal presents itself.
    private func isActuallyOnScreen(now: TimeInterval) -> Bool {
        let pollInterval = isParked ? Self.parkedInterval : 0.25
        if now - lastOnScreenCheck < pollInterval { return lastOnScreenResult }
        lastOnScreenCheck = now

        guard let window, window.isVisible else {
            lastOnScreenResult = false
            return false
        }
        // Cheapest signal first: the legacy check is a process lookup, the
        // wallpaper one copies the whole on-screen window list.
        let seenHost = isPreview || Self.hasLegacyController || Self.hasWallpaperSurface
        if seenHost { hasSeenHostThisRun = true }
        lastOnScreenResult = seenHost || !hasSeenHostThisRun
        return lastOnScreenResult
    }

    private static var hasLegacyController: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: engineBundleIdentifier)
            .isEmpty
    }

    private static var hasWallpaperSurface: Bool {
        let wallpaperPIDs = Set(NSRunningApplication
            .runningApplications(withBundleIdentifier: wallpaperBundleIdentifier)
            .map(\.processIdentifier))
        guard !wallpaperPIDs.isEmpty,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]]
        else { return false }

        return windows.contains { window in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else {
                return false
            }
            return wallpaperPIDs.contains(ownerPID)
        }
    }

    private func park(now: TimeInterval) {
        renderer.end(clearFrame: true)
        holdUntil = nil
        isParked = true
        lastOnScreenResult = false
        lastOnScreenCheck = now
        animationTimeInterval = Self.parkedInterval
    }

    public override func animateOneFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        guard isActuallyOnScreen(now: now) else {
            if !isParked || renderer.isRunning { park(now: now) }
            return
        }

        if isParked {
            isParked = false
            animationTimeInterval = frameInterval
        }
        if let deadline = holdUntil {
            if now >= deadline {
                beginSession()
            } else {
                // Deliberately no `animationTimeInterval` assignment here. The
                // tick rate for the hold is set once, where the hold begins.
                //
                // Assigning the property re-arms the host's timer and it fires
                // again immediately, so reassigning every tick is a busy spin —
                // measured at 10,000-46,000 animateOneFrame calls per second
                // while the property itself read a placid 1.3-1.8 Hz. The value
                // is not what matters; the act of setting it is. Parking sets
                // the property once and holds a clean 1.00 Hz, which is the
                // contrast that isolates this.
            }
            return
        }
        if !renderer.isRunning || renderer.gridStale(for: bounds.size) { beginSession() }
        if renderer.advance() {
            setNeedsDisplay(bounds)
        } else {
            renderer.end()
            let seconds = TTFXSettings.holdSeconds
            if seconds > 0 {
                holdUntil = now + seconds
                // The only place the hold's tick rate is set. 10 Hz bounds the
                // overshoot past `deadline` at 0.1s while costing a rounding
                // error next to the frame rate this replaces.
                animationTimeInterval = min(Self.holdTickInterval, seconds)
            } else {
                beginSession()
            }
        }
    }

    public override func draw(_ rect: NSRect) {
        renderer.draw(in: bounds)
    }

    // MARK: Configure sheet

    private var configController: TTFXConfigController?

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        let controller = configController ?? TTFXConfigController()
        configController = controller
        controller.reload()
        return controller.window
    }
}

// MARK: - Live effect preview

/// A miniature screensaver: runs one named effect over the real logo and
/// loops it, so the configure sheet shows what an effect actually looks like
/// rather than describing it.
final class TTFXPreviewView: NSView {
    private let renderer = TTFXRenderer()
    private var timer: Timer?
    private var holdTicks = 0
    private let fps = 60

    var effectName: String? {
        didSet {
            guard effectName != oldValue else { return }
            restart()
        }
    }

    override var isFlipped: Bool { false }

    deinit { stop() }

    func start() {
        stop()
        restart()
        let timer = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the preview keeps animating while a menu or the file
        // panel is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        renderer.end(clearFrame: true)
    }

    private func restart() {
        guard let name = effectName, bounds.width > 10 else { return }
        holdTicks = 0
        renderer.start(effect: name, logo: TTFXSettings.loadLogo(),
                       size: bounds.size, frameRate: fps)
        needsDisplay = true
    }

    private func tick() {
        if holdTicks > 0 {
            holdTicks -= 1
            if holdTicks == 0 { restart() }
            return
        }
        if !renderer.isRunning || renderer.gridStale(for: bounds.size) { restart() }
        if renderer.advance() {
            needsDisplay = true
        } else {
            renderer.end()
            holdTicks = fps  // one second on the finished art, then loop
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        renderer.draw(in: bounds)
    }
}

// MARK: - Configure sheet

/// The System Settings "Options…" sheet. Pure code, no xib: an effect
/// checklist with a live preview, a logo picker, and the size / hold / frame
/// rate knobs. Every control writes straight into the module defaults.
final class TTFXConfigController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow

    /// Art-size slider travel, in canvas columns. The slider reads
    /// left→right as smaller→bigger art, which is inverse to column count.
    private static let columnRange = 50.0...200.0

    private let logoValue = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider(value: 0, minValue: columnRange.lowerBound,
                                      maxValue: columnRange.upperBound,
                                      target: nil, action: nil)
    private let sizeHint = NSTextField(labelWithString: "")
    private let holdSlider = NSSlider(value: 2, minValue: 0, maxValue: 10,
                                      target: nil, action: nil)
    private let holdHint = NSTextField(labelWithString: "")
    private let ratePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let preview = TTFXPreviewView()
    private let selectionHint = NSTextField(labelWithString: "")

    private var enabled: Set<String> = []
    private var defaults: ScreenSaverDefaults? { TTFXSettings.defaults }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "ttfx"
        window.isReleasedWhenClosed = false
        buildUI()
    }

    // MARK: Slider ↔ columns mapping (inverted: bigger art = fewer columns)

    private var sliderColumns: Double {
        Self.columnRange.lowerBound + Self.columnRange.upperBound - sizeSlider.doubleValue
    }

    private func setSlider(columns: Double) {
        sizeSlider.doubleValue =
            Self.columnRange.lowerBound + Self.columnRange.upperBound
            - min(max(columns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
    }

    // MARK: UI

    private func buildUI() {
        // --- effect checklist
        table.headerView = nil
        table.rowHeight = 22
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("effect")))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true

        let all = NSButton(title: "All", target: self, action: #selector(selectAllEffects))
        let none = NSButton(title: "None", target: self, action: #selector(selectNone))
        selectionHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        selectionHint.textColor = .secondaryLabelColor

        // --- live preview
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.wantsLayer = true
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor.separatorColor.cgColor
        preview.widthAnchor.constraint(equalToConstant: 400).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 300).isActive = true
        let previewCaption = NSTextField(labelWithString: "Live preview of the highlighted effect")
        previewCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewCaption.textColor = .secondaryLabelColor

        let listColumn = NSStackView(views: [
            label("Effects in the shuffle:"),
            scroll,
            NSStackView(views: [all, none, selectionHint]).horizontal(),
        ])
        listColumn.orientation = .vertical
        listColumn.alignment = .leading
        listColumn.spacing = 6

        let previewColumn = NSStackView(views: [label(" "), preview, previewCaption])
        previewColumn.orientation = .vertical
        previewColumn.alignment = .leading
        previewColumn.spacing = 6

        let top = NSStackView(views: [listColumn, previewColumn])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 16

        // --- knobs
        logoValue.lineBreakMode = .byTruncatingMiddle
        logoValue.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Choose File…", target: self, action: #selector(chooseLogo))
        let builtin = NSButton(title: "Use Built-in", target: self, action: #selector(useBuiltinLogo))

        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        let smaller = caption("Smaller"), bigger = caption("Bigger")

        holdSlider.isContinuous = true
        holdSlider.target = self
        holdSlider.action = #selector(holdChanged)

        for (title, fps) in [("30 fps", 30), ("60 fps (default)", 60), ("120 fps (Omarchy)", 120)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = fps
            ratePopup.menu?.addItem(item)
        }
        ratePopup.target = self
        ratePopup.action = #selector(rateChanged)

        // Only meaningful for ANSI art — plain ASCII has no color to keep.
        for (title, key) in [("Let the effect color it", "ignore"),
                             ("Keep art colors where the effect allows", "dynamic"),
                             ("Always keep art colors", "always")]
        {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = key
            colorPopup.menu?.addItem(item)
        }
        colorPopup.target = self
        colorPopup.action = #selector(colorModeChanged)

        for hint in [sizeHint, holdHint] {
            hint.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            hint.textColor = .secondaryLabelColor
            hint.widthAnchor.constraint(equalToConstant: 96).isActive = true
        }

        let done = NSButton(title: "Done", target: self, action: #selector(dismiss))
        done.keyEquivalent = "\r"

        let rows = NSStackView(views: [
            top,
            row("Logo:", [logoValue, choose, builtin]),
            row("Art size:", [smaller, sizeSlider, bigger, sizeHint]),
            row("Hold finished text:", [holdSlider, holdHint]),
            row("Animation:", [ratePopup, NSView()]),
            row("ANSI art color:", [colorPopup, NSView()]),
            row("", [NSView(), done]),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        rows.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(rows)
        window.contentView = content
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    private func caption(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        return f
    }

    private func row(_ title: String, _ views: [NSView]) -> NSStackView {
        let head = NSTextField(labelWithString: title)
        head.alignment = .right
        head.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let stack = NSStackView(views: [head] + views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.widthAnchor.constraint(equalToConstant: 656).isActive = true
        return stack
    }

    /// Sync every control to the current defaults; called each time the sheet
    /// is about to show.
    func reload() {
        TTFXSettings.refresh()
        if let path = defaults?.string(forKey: "LogoPath") {
            logoValue.stringValue = path
        } else if defaults?.string(forKey: "LogoText") != nil {
            logoValue.stringValue = "Custom logo (picked file)"
        } else {
            logoValue.stringValue = "Built-in logo"
        }
        setSlider(columns: Double(TTFXSettings.targetColumns))
        holdSlider.doubleValue = TTFXSettings.holdSeconds
        ratePopup.selectItem(withTag: TTFXSettings.frameRate)
        let colorKey = defaults?.string(forKey: "ArtColors") ?? "ignore"
        colorPopup.selectItem(at: colorPopup.itemArray.firstIndex {
            $0.representedObject as? String == colorKey
        } ?? 0)
        enabled = Set(TTFXSettings.enabledEffects)
        table.reloadData()
        if table.selectedRow < 0, !TTFXSettings.effectNames.isEmpty {
            let first = TTFXSettings.effectNames.firstIndex { enabled.contains($0) } ?? 0
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
        updateHints()
        startPreview()
    }

    private func startPreview() {
        preview.effectName = currentEffectName
        preview.start()
    }

    private var currentEffectName: String? {
        let row = table.selectedRow
        return row >= 0 && row < TTFXSettings.effectNames.count
            ? TTFXSettings.effectNames[row] : TTFXSettings.effectNames.first
    }

    private func updateHints() {
        sizeHint.stringValue = "≈ \(Int(sliderColumns)) columns"
        holdHint.stringValue = String(format: "%.1f s", holdSlider.doubleValue)
        switch enabled.count {
        case TTFXSettings.effectNames.count:
            selectionHint.stringValue = "All \(enabled.count) effects"
        case 0:
            selectionHint.stringValue = "None selected — all will play"
        default:
            selectionHint.stringValue = "\(enabled.count) of \(TTFXSettings.effectNames.count) selected"
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { TTFXSettings.effectNames.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let name = TTFXSettings.effectNames[row]
        let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(toggleEffect(_:)))
        check.tag = row
        check.state = enabled.contains(name) ? .on : .off
        return check
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        preview.effectName = currentEffectName
    }

    @objc private func toggleEffect(_ sender: NSButton) {
        let name = TTFXSettings.effectNames[sender.tag]
        if sender.state == .on { enabled.insert(name) } else { enabled.remove(name) }
        TTFXSettings.setEnabledEffects(TTFXSettings.effectNames.filter { enabled.contains($0) })
        // Clicking a checkbox doesn't move the selection on its own; follow it
        // so the preview shows what was just toggled.
        table.selectRowIndexes([sender.tag], byExtendingSelection: false)
        updateHints()
    }

    @objc private func selectAllEffects() {
        enabled = Set(TTFXSettings.effectNames)
        TTFXSettings.setEnabledEffects(TTFXSettings.effectNames)
        table.reloadData()
        updateHints()
    }

    @objc private func selectNone() {
        enabled = []
        TTFXSettings.setEnabledEffects([])
        table.reloadData()
        updateHints()
    }

    // MARK: Actions

    @objc private func chooseLogo(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a plain-text ASCII art file"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            // Snapshot the content alongside the path: the open panel grants
            // read access now, but the screensaver host's sandbox may not
            // reach this path later — display must never depend on it.
            self.defaults?.set(url.path, forKey: "LogoPath")
            self.defaults?.set(text, forKey: "LogoText")
            self.defaults?.synchronize()
            self.logoValue.stringValue = url.path
            self.restartPreviewLogo()
        }
    }

    @objc private func useBuiltinLogo(_ sender: Any?) {
        defaults?.removeObject(forKey: "LogoPath")
        defaults?.removeObject(forKey: "LogoText")
        defaults?.synchronize()
        logoValue.stringValue = "Built-in logo"
        restartPreviewLogo()
    }

    /// The preview caches the logo per run; bounce the effect to pick up a
    /// new one immediately.
    private func restartPreviewLogo() {
        let name = preview.effectName
        preview.effectName = nil
        preview.effectName = name
    }

    @objc private func sizeChanged(_ sender: Any?) {
        defaults?.set(sliderColumns, forKey: "Columns")
        // The sheet wins over the scripted point-size override.
        defaults?.removeObject(forKey: "FontSize")
        defaults?.synchronize()
        updateHints()
    }

    @objc private func holdChanged(_ sender: Any?) {
        defaults?.set(holdSlider.doubleValue, forKey: "HoldSeconds")
        defaults?.synchronize()
        updateHints()
    }

    @objc private func rateChanged(_ sender: Any?) {
        defaults?.set(ratePopup.selectedTag(), forKey: "FrameRate")
        defaults?.synchronize()
    }

    @objc private func colorModeChanged(_ sender: Any?) {
        let key = colorPopup.selectedItem?.representedObject as? String ?? "ignore"
        if key == "ignore" {
            defaults?.removeObject(forKey: "ArtColors")
        } else {
            defaults?.set(key, forKey: "ArtColors")
        }
        defaults?.synchronize()
        restartPreviewLogo()
    }

    @objc private func dismiss(_ sender: Any?) {
        preview.stop()
        defaults?.synchronize()
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }
}

private extension NSStackView {
    func horizontal() -> NSStackView {
        orientation = .horizontal
        spacing = 8
        return self
    }
}
