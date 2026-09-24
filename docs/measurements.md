# What this thing actually costs

Numbers, and the harnesses that produced them, so the next person does not have to take the README's word for anything. Everything here was measured on macOS 27 (Apple silicon) against a Developer ID signed `ttfx.saver` built from this tree.

The tools live in `tools/` and write nothing outside `out/`:

```sh
swiftc -O -o out/saver-probe   tools/saver-probe.swift    && out/saver-probe ttfx.saver --cycles 40
swiftc -O -o out/preview-probe tools/preview-probe.swift  && out/preview-probe ttfx.saver
cc -O2     -o out/engine-footprint tools/engine-footprint.c && out/engine-footprint
```

None of them opens a window on any display or takes focus: the windows are placed far outside every screen and the process runs with activation policy `.prohibited`.

## Off screen really is free

The claim in the README is that the view does no work while it is off screen. Driving the real bundle through a real dismissal — window ordered out, `stopAnimation` deliberately not called, which is how macOS has actually behaved since Sonoma:

| | running | parked |
|---|---|---|
| tick interval | 0.1 s | 1.0 s |
| cpu per tick | 2.34 ms | 0.0007 ms |
| footprint | 52.5 MB | 52.6 MB, flat over 200,000 ticks |

A parked tick costs about **1/3,300** of a running one. What is left is the cached visibility verdict being read, and once a second at that.

Parking frees the engine session, but the process footprint does not drop when it does — see the last section for why. Nothing is still running; the memory is simply not handed back.

## No leak across cycles

- 16,000 ticks across 40 effect cycles: +380 bytes/tick, and the footprint ends *below* its peak.
- 60 start/stop cycles: min 54.3 MB, max 66.3 MB, drift +1.0 MB. Up as often as down.
- `leaks` over the engine's create/advance/free loop: **0 leaks, 0 bytes**.

Two things had to be fixed in the harness before these numbers meant anything, both worth knowing because they are easy to hit again:

- **Measure `phys_footprint`, never `resident_size`.** `resident_size` counts every mapped page the process has touched, framework text included, so it climbs as new code paths run. Reading it made an earlier version of this probe report 45 MB growing to 171 MB with nothing wrong anywhere; `heap` put the real footprint at 34 MB over a 3 MB malloc heap.
- **Drain an autorelease pool per tick.** The host's run loop does; a bare tick loop does not, and without it the probe invents a steady ~57 KB per effect cycle of growth that is entirely its own undrained pool.

A third: `displayIfNeeded()` on a window placed off every display may skip the draw entirely, which moved the measured frame cost by 40x between runs. The probe draws into a bitmap with `cacheDisplay(in:to:)` instead, so the glyph rendering is always actually done.

## The configure sheet's preview used to run forever

The live preview in the Options sheet is a 60 Hz engine session inside System Settings — a process people leave open for hours. Until this was fixed, the only thing that stopped it was the sheet's own Done button, which calls `dismiss(_:)`. A sheet closed any other way left it running:

| | before | after |
|---|---|---|
| sheet open | 63.1% of a core | 43.3% of a core |
| sheet closed, `dismiss(_:)` never called | **79.4% of a core, indefinitely** | 0.8% of a core |
| sheet reopened | — | 44.4% of a core |

Closed cost *more* than open, because a hidden window does not coalesce the drawing away.

The fix is the same principle as the saver's own visibility gate: the preview's timer checks its window and stops itself, and fails open until the sheet has been seen on screen — `configureSheet` calls `reload()`, and so `start()`, before System Settings presents the window, so the first ticks legitimately run against a hidden sheet. `out/preview-probe` is the regression test.

## Large canvases: the allocator keeps what the engine gives back

`tools/engine-footprint.c` calls `ttfx_session_new` / `ttfx_session_free` straight through the C surface, with no Swift or AppKit involved. Sweeping the canvas:

```
  cols x rows   cells    per new/free cycle   after 12 cycles
   110 x  37     4070          +0.22 MB           +2.7 MB
   130 x  44     5720          +0.00 MB           +0.0 MB
   150 x  50     7500          +0.01 MB           +0.1 MB
   170 x  57     9690          +3.88 MB          +46.6 MB
   220 x  74    16280          +6.63 MB          +79.5 MB
   300 x 100    30000         +12.28 MB         +147.3 MB
```

Somewhere between 7,500 and 9,690 cells the cost of a session stops being returned, and above it each new/free pair leaves roughly 0.4 KB per cell behind. It is the same for every effect and the same with zero frames drawn, so it is the session, not the animation.

It is **not a leak**. `leaks` reports nothing, and `malloc_zone_pressure_relief` recovers nothing, because there is nothing unreachable to recover. `vmmap` names it exactly:

```
Malloc Small (empty)   308.0M virtual   200.8M resident   200.8M dirty   77 regions
```

Whole malloc regions with no live allocations left in them, still resident and still dirty. The engine frees correctly; the allocator does not hand the pages back. The process is charged for them either way, and `legacyScreenSaver` is long-lived.

End to end through the real view it is bounded, but the bound moves with the canvas:

| display | canvas | footprint over 60 start/stop cycles |
|---|---|---|
| 1728x1117 (16:10 laptop) | default | 54.5 – 90.4 MB, drift −17.4 MB |
| 2880x5120 (5K in portrait) | default | 254.5 – 415.8 MB, drift −58.1 MB |

Columns is the knob that reaches this deliberately: the grid targets a column count, so resolution barely moves it, but a tall display or a high **Art size** setting does. The shipped default on a normal wide display sits below the threshold. Worth raising with [upstream ttfx](https://github.com/omacom-io/ttfx) rather than working around here, since the allocation belongs to the engine.
