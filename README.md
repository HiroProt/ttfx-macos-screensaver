# ttfx-macos-screensaver

Terminal text effects as a macOS screensaver. Your ASCII logo, 37 animated
effects, a random one each cycle.

![demo](docs/demo.gif)

Built on **[ttfx](https://github.com/omacom-io/ttfx)** by 37signals/omacom-io —
itself a byte-exact Rust port of
**[TerminalTextEffects](https://github.com/ChrisBuilds/terminaltexteffects)**
by ChrisBuilds. Every effect and the entire animation engine are theirs. This
project is the macOS shell around them, modeled on
[Omarchy](https://github.com/basecamp/omarchy)'s screensaver.

**Unofficial** — not affiliated with, endorsed by, or supported by 37signals,
omacom-io, Basecamp, or ChrisBuilds.

## Install

Download **ttfx-screensaver.zip** from the
[latest release](https://github.com/HiroProt/ttfx-macos-screensaver/releases/latest),
unzip it, and double-click `ttfx.saver`. macOS opens Screen Saver settings
and offers to install it; pick **ttfx** under "Other".

Universal binary, macOS 11 and later, Apple Silicon and Intel.

<details>
<summary>Build it yourself instead</summary>

Requires [Rust](https://rustup.rs) and Xcode command line tools
(`xcode-select --install`).

```sh
git clone https://github.com/HiroProt/ttfx-macos-screensaver
cd ttfx-macos-screensaver
./build.sh --install
```

That signs the bundle for your own machine only, which is all you need
locally. `./release.sh --notarize` produces the distributable, Apple-notarized
build.
</details>

## Use your own logo

Open **Options…** in Screen Saver settings, click **Choose File…**, and pick
any plain-text file. That's it — it takes effect on the next cycle.

`examples/logos/` has a couple to start from. The art should be plain text;
a file wider than the canvas gets clipped, so keep it under about 100
columns unless you also turn the art size down.

### Making good ASCII art

**Text into a big block wordmark.** The fastest route is
[patorjk.com/software/taag](https://patorjk.com/software/taag/) — type your
text, page through hundreds of FIGlet fonts, copy the result. Locally, the
same thing is `brew install figlet` and:

```sh
figlet -f big "hello" > logo.txt
figlet -f banner3 -w 200 "hello" > logo.txt   # chunkier, wider
showfigfonts | less                            # browse installed fonts
```

Fonts made of block characters (`█`, `░`) read better on a screensaver than
fine outline fonts, because each cell becomes a solid tile the effects can
color. The two files in `examples/logos/` are that style.

**An image into ASCII.** [`chafa`](https://hpjansson.org/chafa/) gives the
best results and can restrict itself to characters that suit this use:

```sh
brew install chafa
chafa --format symbols --colors none --symbols block --size 90x30 logo.png > logo.txt
```

`jp2a` (also in Homebrew) is a simpler alternative. Whatever you use, aim for
high contrast — mid-tones turn into visual mush once an effect starts
recoloring everything.

### ANSI art (colored)

Color already in the file is supported. **Options… → ANSI art color** decides
what happens to it:

| Setting | What you get |
|---|---|
| Let the effect color it *(default)* | The art's color is discarded; effects own every color |
| Keep art colors where the effect allows | The art's own palette shows through, effects color the rest |
| Always keep art colors | The art's palette always wins |

So a piece of ANSI art can animate *in* with an effect and settle into its
own true colors. Escape sequences are read as 24-bit and 256-color SGR;
anything else in the file is passed through as text.
`examples/logos/color-ansi.txt` is a small one to try it with.

For authoring, [Moebius](https://blocktronics.github.io/moebius/) is a modern
ANSI editor with a native macOS build, and
[PabloDraw](https://picoe.ca/products/pablodraw/) is the long-standing
cross-platform one. To convert an image straight to colored ANSI, drop the
`--colors none` from the command above:

```sh
chafa --format symbols --colors full --size 90x30 logo.png > logo.txt
```

That output can be used as-is — the cursor and reverse-video sequences chafa
emits are handled. Note it leans on background-color blocks, which look great
but give the effects less to animate than foreground glyphs do. Try both.

## Settings

Everything is behind **Options…**, and applies at the next effect cycle:

- **Effects** — a checklist of all 37, so the shuffle can be any subset. The
  highlighted row plays in a **live preview** beside the list: a real engine
  session over your real logo, scaled down.
- **Logo** — the file picker described above, or the built-in logo.
- **Art size** — the canvas targets ~110 columns at any resolution; the
  slider moves that between 200 (small art) and 50 (huge).
- **Hold finished text** — how long the completed logo sits before the next
  effect.
- **Animation** — 30 / 60 / 120 fps. Each tick advances the effect exactly
  one frame, so this is animation *speed* as well as smoothness: 120 plays
  twice as fast as 60 and matches what Omarchy passes tte. Upstream's default
  is 60, which is also the default here. Your display's refresh rate is the
  ceiling.
- **ANSI art color** — as above.

The same knobs are scriptable — the sheet and the saver share one defaults
domain:

```sh
defaults -currentHost write gg.ka.ttfx Columns -float 70
defaults -currentHost write gg.ka.ttfx FrameRate -int 120
defaults -currentHost write gg.ka.ttfx Effects -array matrix rain waves
defaults -currentHost delete gg.ka.ttfx Effects        # back to all 37
```

| Key | Meaning |
|---|---|
| `LogoPath` | path to a logo file, re-read each cycle when reachable |
| `LogoText` | logo content snapshot, used when `LogoPath` can't be read |
| `Columns` | target canvas width in cells (40–300, default 110) |
| `FontSize` | exact cell point size; overrides `Columns` |
| `Effects` | array of effect names in the shuffle; unset = all |
| `HoldSeconds` | hold on the finished text, seconds (default 2) |
| `FrameRate` | ticks per second: 15–240, default 60 |
| `ArtColors` | `ignore` (default), `dynamic`, or `always` |

A picked logo is stored as both a path and a content snapshot: the open panel
grants read access at pick time, but the screensaver host's sandbox may not
reach that path later, and the logo must render regardless.

## How it works

A real `ScreenSaverView`, not a terminal in a window. The ttfx engine is
linked in as a static library and pulled for one frame per tick; the Swift
side interprets the ANSI color runs and draws the cell grid with CoreText.
No subprocess — which also sidesteps the sandbox that makes spawning
binaries unreliable inside macOS's screensaver host.

ttfx is consumed as an unmodified dependency pinned to a release tag. This is
not a fork and vendors no upstream code: everything the bridge needs is
already ttfx's public API, so upstream stays upstream.

```
src/lib.rs                    C API over the ttfx engine (the whole upstream coupling)
Sources/TTFXSaverView.swift   renderer, SGR interpreter, configure sheet
Sources/ttfx.h                the bridge header Swift imports
Resources/                    Info.plist, default logo, picker thumbnails
build.sh                      cargo → swiftc → lipo → codesign, no Xcode project
release.sh                    Developer ID signing, notarization, stapling
examples/                     starter logos and the terminal equivalent
```

## Troubleshooting

**Options… does nothing, or changes don't apply.** macOS caches the loaded
bundle. Quit System Settings with ⌘Q, then
`killall legacyScreenSaver`, and reopen.

**"ttfx.saver is damaged" or a Gatekeeper block** on a build you made
yourself: `./build.sh` signs ad-hoc for the local machine, which is fine, but
a bundle that has been zipped and moved between Macs needs
`xattr -dr com.apple.quarantine ~/Library/Screen\ Savers/ttfx.saver`.
Release downloads are notarized and don't need this.

## Uninstall

```sh
rm -rf ~/Library/Screen\ Savers/ttfx.saver
defaults -currentHost delete gg.ka.ttfx
```

## License

MIT — see [LICENSE](LICENSE), which carries this project's copyright
alongside ttfx's and TerminalTextEffects', and [NOTICE](NOTICE) for the
attribution chain in full. The engine is statically linked into the built
bundle, so both upstream copyrights travel with any binary produced here.

By [Martin May](https://github.com/HiroProt) / [23made](https://23made.com).
