# Security

## Reporting a vulnerability

Please report anything security-relevant privately via
[GitHub's private vulnerability reporting](https://github.com/HiroProt/ttfx-macos-screensaver/security/advisories/new)
rather than a public issue. I'll acknowledge within a week.

If the issue is in the animation engine rather than this wrapper, it belongs
upstream at [omacom-io/ttfx](https://github.com/omacom-io/ttfx) — see below
for where the boundary sits.

## What this software does and doesn't do

Worth knowing before you audit it:

- It reads one file: the logo you pick, or the one bundled in the app.
- It writes nothing except its own preferences (`gg.ka.ttfx`, ByHost).
- It makes no network connections, and has no update checker, telemetry, or
  analytics of any kind.
- It runs inside `legacyScreenSaver`, Apple's host process for third-party
  screen savers, with that process's privileges. It is not a launch agent,
  daemon, or login item, and installs nothing outside
  `~/Library/Screen Savers`.

The parts that process untrusted input are the logo parser and the SGR
escape-sequence interpreter, since a logo file may come from anywhere. The
engine's frame output is parsed by `TTFXRenderer` in
`Sources/TTFXSaverView.swift`; the logo itself is parsed by ttfx upstream.

Panics crossing the Rust/C boundary are caught in `src/lib.rs` — unwinding
into the host process would abort the system screen saver, so every entry
point traps.

## Releases

Release binaries are built by `ship.sh` on a workstation, signed with a
Developer ID Application certificate, notarized by Apple, and stapled. CI has
read-only permissions and does not publish anything.

To verify a download yourself:

```sh
spctl --assess --type install -vv ttfx.saver   # expect: source=Notarized Developer ID
codesign -dv --verbose=2 ttfx.saver            # expect: Developer ID Application: 23made LLC (YN57TPCA6Y)
xcrun stapler validate ttfx.saver
```

Each release lists the artifact's SHA-256.
