# Contributing

## Effect ideas go upstream

This repository is the macOS shell: a `ScreenSaverView`, an SGR interpreter,
a settings sheet, and the bundle build. It contains none of the animation.

- A new effect, or a change to how an existing one looks → **[ChrisBuilds/terminaltexteffects](https://github.com/ChrisBuilds/terminaltexteffects)**,
  where the effects are designed.
- Engine behavior, CLI flags, rendering fidelity → **[omacom-io/ttfx](https://github.com/omacom-io/ttfx)**,
  the Rust port this links against.
- The screen saver itself — settings, rendering, packaging, install → here.

That split is deliberate: ttfx is consumed as an unmodified pinned
dependency, so anything that would require patching it belongs upstream.

## Building

```sh
./build.sh --install
```

Needs [Rust](https://rustup.rs) and Xcode command line tools. There's no
Xcode project; `build.sh` runs cargo, then swiftc, then lipo, then codesign.

## Testing changes

There's no unit-test suite for the AppKit side — it's a renderer, so the
useful checks are visual and behavioral:

- Install and let the screen saver actually run, at a real resolution.
- Open **Options…** and confirm every control still writes its preference
  and takes effect on the next cycle.
- Watch `legacyScreenSaver` in Activity Monitor after dismissing: it should
  drop to ~0% CPU, because the view stops working when off screen. This one
  regresses easily and costs users battery, so please check it.

If you change the C API in `src/lib.rs`, update `Sources/ttfx.h` in the same
commit — nothing checks that they agree.

## A warning about "obvious" cleanups

Two things look wrong and aren't:

- Full-screen visibility is gated on either the legacy `ScreenSaverEngine`
  controller or WallpaperAgent's on-screen compositor surface, **not** just
  `window.isVisible`, `occlusionState`, or the remote view's own WindowServer
  entry. On current macOS releases the first stays true after dismissal, while
  the latter two can be false or absent during genuine extension-hosted
  playback. Modern launch paths need not keep `ScreenSaverEngine` alive, which
  is why the WallpaperAgent fallback is required. Embedded previews use
  `ScreenSaverView.isPreview`; a parked instance checks once per second and
  does no rendering work.
- The engine session is recreated per effect cycle rather than kept alive.
  That's what lets settings changes apply without a restart.

Both have comments saying so. Please leave them.

## The picker thumbnail does not work on macOS 26 (Tahoe), and that's not a bug here

`Resources/thumbnail.png` and `thumbnail@2x.png` follow Apple's convention
for a screen saver's tile in the picker. On Tahoe the tile shows a generic
blue swirl instead, and no amount of fiddling changes it. Before you try:

- The files are installed in the right place at Apple's exact dimensions
  (90×58 and 180×116), in the same format as Apple's own
  (`Random.saver`): 8-bit RGBA PNG, non-interlaced, sRGB.
- It is not a quarantine problem. Clearing `com.apple.quarantine` off the
  installed bundle changes nothing.
- It is not a stale cache. Restarting `WallpaperLegacy`, `legacyScreenSaver`
  and System Settings, and touching the bundle, change nothing.
- The blue swirl is Apple's stock legacy art — byte for byte what ships as
  `Random.saver`'s own `thumbnail.png`. `WallpaperLegacyExtension` contains
  a `Default` asset and log strings for failing to load a legacy thumbnail,
  so the fallback is deliberate.

Apple's logging for that path is suppressed, so "ignored" and "rejected"
can't be told apart from outside. The files stay in the bundle because they
cost 15 KB, they are correct by the documented convention, and older macOS
releases used them — but do not expect them to do anything on Tahoe, and
please don't spend an evening on it like I did.

## Commits and PRs

Explain *why* in the commit message; the diff already shows what. If you
found something by measuring, include the numbers.
