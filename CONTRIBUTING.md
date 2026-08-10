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
- Check the other direction too, from **every** launch path — idle timeout,
  the System Settings preview, and `open -a ScreenSaverEngine`. The off-screen
  check above is what decides whether to render at all, so getting it wrong in
  this direction is a black screen with no way back, not a battery bug. It is
  the more expensive failure and the easier one to miss.

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

  Until one of those signals has been seen during an animation run, an
  unrecognized one means "keep animating" rather than "park", so an unfamiliar
  host fails toward wasted CPU instead of a black screen. Both are wrong; only
  one is recoverable. Note also that the WallpaperAgent signal is global rather
  than per-view, so a video desktop wallpaper or a second display genuinely
  playing can hold it true — which lands back on the old behavior, never
  past it.
- The engine session is recreated per effect cycle rather than kept alive.
  That's what lets settings changes apply without a restart.

Both have comments saying so. Please leave them.

## What the host did in one measured session

One observation, not a law. macOS 26 (Darwin 25.6), single display, one login
session, five launches through `ScreenSaverEngine`, with the view instrumented
via `os_log` and a per-instance UUID. Other launch paths, other releases, and
more than one display are unmeasured. Treat this as a starting point for your
own measurement rather than as settled behavior:

- **`stopAnimation` was not called once.** Five launches, five dismissals, zero
  calls. Every park came from `animateOneFrame` noticing it was off screen. In
  that session recovery depended entirely on `startAnimation` resetting the
  parked state, which is what that override is for.
- **The first view was reused on each later launch.** Launch 1 created a view;
  launches 2 through 5 restarted that same instance *and* created a new one.
  The views created in between were started once and not woken again before the
  session ended.
- **So two instances rendered concurrently** on launches 2 through 5: the
  genuinely-presenting view and a stale one. The stale view's window kept
  reporting `isVisible == true`, which is why the host-signal check exists —
  under an `isVisible`-only gate such a view keeps animating for as long as the
  host process lives.
- **No view was deallocated during the session.** One accumulated per launch.
  Parked views are cheap — `park` frees the engine session and clears the
  frame — but nothing observed released them.

A second instrumented session, same machine, added two more:

- **`animationTimeInterval` is honored, including while parked** — measured at
  exactly 1.00 Hz across eight consecutive windows after a park. An earlier
  reading of this as "the host overrides it and drives at panel rate" was wrong,
  and wrong because of the preferences trap below.
- **Both views in an overlap genuinely render.** The stale view logged non-zero
  `draws`, not merely engine advances, so a concurrent stale instance costs a
  full second renderer rather than engine time alone.

## The preferences trap that will waste your afternoon

The saver runs inside a sandboxed appex, so `ScreenSaverDefaults` resolves to
the **container** copy:

    ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/
        Data/Library/Preferences/ByHost/gg.ka.ttfx.<uuid>.plist

`defaults -currentHost write gg.ka.ttfx ...` writes
`~/Library/Preferences/ByHost/` instead — a file the running saver never
opens.
Pinning settings from the command line to control an experiment therefore does
nothing, silently, while the saver keeps using whatever the options sheet last
stored. The sheet is hosted in the same appex, so its writes land correctly;
only the CLI is fooled.

This cost real time here: a whole measured session was interpreted as the host
ignoring the frame-rate setting, when the setting had simply never arrived. If
you pin anything for a test, read it back **from the container path** and
confirm the value the saver reports, not the value `defaults read` reports.

## Set `animationTimeInterval` once, never per tick

Assigning `animationTimeInterval` re-arms the host's timer and it fires again
immediately. Assign it on every tick and you have a busy spin, whatever value
you assign.

The hold used to recompute `min(parkedInterval, deadline - now)` each tick.
Measured: **10,000-46,000 `animateOneFrame` calls per second** while the
property itself read a placid 1.3-1.8 Hz. Flooring the value changed nothing,
which is what isolated the cause — the value was never the problem. Setting it
once, when the hold begins, took the same windows to **1-12 ticks**.

Parking is the working example: it assigns once and holds a clean 1.00 Hz. Any
new code that derives an interval from a countdown will reintroduce this, so
derive it once and leave the property alone.

## Per-view signals that did not discriminate

If you want to tell *this* view apart from a stale sibling — which would fix
both the two-renderer overlap and the multi-display case — these were measured
and do not discriminate. Both the live and the stale view report identically:

- `occlusionState.contains(.visible)` — **false for both**, including the view
  actually on screen. This is the measurement behind rejecting it.
- The view's own `windowNumber`, looked up in the on-screen window list —
  **absent for both**, so the remote view has no on-screen WindowServer entry
  to find.

`window.level` does discriminate: the presenting view sits at `Int32.min + 23`
(-2147483625, the same level WallpaperAgent's own screen saver surface uses),
and the stale one is demoted to `0` the moment another launch takes over. Note
this is *not* `kCGScreenSaverWindowLevelKey` (1000), which the modern host does
not use at all. It is a promising per-view discriminator and it is deliberately
not implemented: it was observed on one launch path, on one display, on one
release, and gating rendering on it is a narrowing — the direction that fails
to a black screen. Validate across every launch path and a second display
before trusting it.

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
