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

- Visibility is gated on `window.isVisible`, **not** `occlusionState`, even
  though the latter is the documented signal. It reports false for an
  ordered-front window in this context, which would freeze the animation.
- The engine session is recreated per effect cycle rather than kept alive.
  That's what lets settings changes apply without a restart.

Both have comments saying so. Please leave them.

## Commits and PRs

Explain *why* in the commit message; the diff already shows what. If you
found something by measuring, include the numbers.
