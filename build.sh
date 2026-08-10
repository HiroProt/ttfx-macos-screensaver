#!/bin/sh
# Build ttfx.saver — universal (arm64 + x86_64), ad-hoc signed.
#
#   ./build.sh            # both architectures if their Rust targets are installed
#   ./build.sh --install  # ...and copy into ~/Library/Screen Savers
#
# There is no Xcode project: cargo builds the engine + FFI shim into a static
# library per architecture, swiftc compiles and links the screensaver against
# it per architecture, and lipo glues the two into one binary.
set -e

DEPLOY_TARGET=11.0
export MACOSX_DEPLOYMENT_TARGET=$DEPLOY_TARGET

here=$(cd "$(dirname "$0")" && pwd)
bundle="$here/ttfx.saver"
work="$here/target/bundle"

installed_targets=$(rustup target list --installed 2>/dev/null || echo "")
archs=""
add_arch() { # rust_target  swift_target  lipo_name
  if [ -z "$installed_targets" ] || echo "$installed_targets" | grep -q "^$1$"; then
    echo "==> $3"
    cargo build --release --target "$1"
    mkdir -p "$work"
    swiftc -O \
      -module-name TTFXSaver \
      -target "$2" \
      -import-objc-header "$here/Sources/ttfx.h" \
      -framework ScreenSaver -framework AppKit \
      -emit-library \
      "$here/Sources/TTFXSaverView.swift" \
      "$here/target/$1/release/libttfx_ffi.a" \
      -o "$work/ttfx-saver-$3"
    archs="$archs $work/ttfx-saver-$3"
  else
    echo "==> skipping $3 (rustup target add $1)"
  fi
}

add_arch aarch64-apple-darwin "arm64-apple-macos$DEPLOY_TARGET"  arm64
add_arch x86_64-apple-darwin  "x86_64-apple-macos$DEPLOY_TARGET" x86_64

[ -n "$archs" ] || { echo "no architectures built" >&2; exit 1; }

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$here/Resources/Info.plist" "$bundle/Contents/"
cp "$here/Resources/logo.txt" "$bundle/Contents/Resources/"
# thumbnail.png / thumbnail@2x.png are what System Settings shows in the
# screensaver picker; without them the tile is a generic blue placeholder.
cp "$here/Resources/thumbnail.png" "$here/Resources/thumbnail@2x.png" \
   "$bundle/Contents/Resources/"
# shellcheck disable=SC2086
lipo -create $archs -output "$bundle/Contents/MacOS/ttfx-saver"

# Ad-hoc signature: enough for the machine that built it. Distributing to
# other Macs needs a Developer ID identity and notarization — see README.
codesign --force -s - "$bundle"

echo "built: $bundle ($(lipo -archs "$bundle/Contents/MacOS/ttfx-saver"))"

if [ "$1" = "--install" ]; then
  dest="$HOME/Library/Screen Savers"
  mkdir -p "$dest"
  rm -rf "$dest/ttfx.saver"
  cp -R "$bundle" "$dest/"
  # The screensaver host caches the bundle it loaded; without this a
  # reinstall can keep running the old code until you log out.
  killall legacyScreenSaver 2>/dev/null || true
  echo "installed: $dest/ttfx.saver"
fi
