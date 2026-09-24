#!/bin/sh
# Ship a release, end to end:
#
#   preflight → build + sign + notarize + staple + package → GitHub release →
#   verify the published downloads the way a stranger's Mac will →
#   bump the Homebrew cask → push the tap
#
# Two artifacts ship: an installer package, which is what the cask and the
# README point at, and the bare zipped bundle for people who want it. The
# package exists because files an installer lays down carry no quarantine,
# and a quarantined screen saver can be refused at load with "Apple could not
# verify ttfx.saver is free of malware".
#
#   ./ship.sh              # ship the version in Resources/Info.plist
#   ./ship.sh --dry-run    # do everything except publish and push
#
# Notarization credentials come from a notarytool keychain profile, created
# once (see the preflight message for the exact command). They are deliberately
# not passed on a command line: notarytool takes --password as an argument, and
# an argument is visible in `ps` to every process on the machine for as long as
# the submission runs. This script used to do that.
#
# Requires: gh (authenticated), a notarytool keychain profile, and both
# Developer ID certificates — Application (signs the bundle) and Installer
# (signs the pkg). 1Password is only needed for the one-time profile setup.
set -e

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

DRY_RUN=false
[ "$1" = "--dry-run" ] && DRY_RUN=true

# Plain ASCII on purpose: op secret references reject characters like an
# em-dash in the item title.
NOTARY_OP_ITEM=${NOTARY_OP_ITEM:-"op://23made/Apple Notarization 23made"}
NOTARY_PROFILE=${NOTARY_PROFILE:-ttfx-notary}
TAP_DIR=${TAP_DIR:-"$HOME/Projects/homebrew-tap"}
CASK=$TAP_DIR/Casks/ttfx-screensaver.rb

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
# Everything that can be checked before doing irreversible work, is.

say "Preflight"
command -v gh >/dev/null || die "GitHub CLI (gh) not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "no Developer ID Application identity in the keychain"
# A second, different certificate — and `security find-identity` only lists it
# without -p codesigning, because signing an installer is not code signing.
security find-identity -v | grep -q "Developer ID Installer" \
  || die "no Developer ID Installer identity in the keychain (the package needs it; create it at https://developer.apple.com/account/resources/certificates/add)"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || die "on branch '$branch', expected main"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  || die "local main and origin/main differ — push or pull first"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
tag="v$version"
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 \
  && die "$tag already exists on origin — bump CFBundleShortVersionString first"
gh release view "$tag" >/dev/null 2>&1 \
  && die "a GitHub release for $tag already exists"

[ -d "$TAP_DIR" ] || die "tap not found at $TAP_DIR (set TAP_DIR)"
[ -f "$CASK" ] || die "cask not found at $CASK"
[ -z "$(git -C "$TAP_DIR" status --porcelain)" ] || die "tap working tree is dirty"

echo "  version:  $version"
echo "  tag:      $tag"
echo "  dry run:  $DRY_RUN"

# --- credentials -----------------------------------------------------------
# Nothing secret passes through this script. The profile lives in the keychain
# and notarytool reads it by name.

say "Checking the notarization credentials"
# Cheapest call that actually proves the profile works. Worth the couple of
# seconds: the alternative is finding out after a full build and an upload
# that the credentials were wrong.
#
# No --limit here: notarytool's `history` does not take one, and asking for it
# fails the check for the wrong reason — which is exactly what this did on its
# first real use, reporting a missing profile against a profile that worked.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  die "no working notarytool keychain profile '$NOTARY_PROFILE'.

  Create it once — the password goes in on stdin, so unlike --password it
  never appears in the process table:

    op read \"$NOTARY_OP_ITEM/password\" | xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id \"\$(op read \"$NOTARY_OP_ITEM/username\")\" \\
      --team-id \"\$(op read \"$NOTARY_OP_ITEM/Team ID\")\"

  Override the profile name with NOTARY_PROFILE if you use another."
fi
export NOTARY_PROFILE
echo "  keychain profile: $NOTARY_PROFILE (validated)"

# --- build, sign, notarize -------------------------------------------------

say "Building and notarizing"
./release.sh --notarize

zip="dist/ttfx-screensaver-$version.zip"
pkg="dist/ttfx-screensaver-$version.pkg"
for f in "$pkg" "$zip"; do
  [ -f "$f" ] || die "expected artifact missing: $f"
done
pkgsha=$(shasum -a 256 "$pkg" | cut -d' ' -f1)
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
echo "  package:  $pkg"
echo "  sha256:   $pkgsha"
echo "  zip:      $zip"
echo "  sha256:   $sha"

# Prove both artifacts survive the trip, with the quarantine flag a browser
# download attaches. Catching this here beats catching it in someone's bug
# report — which is exactly how the gate below was found missing.
say "Verifying the artifacts as a downloader would see them"
work=$(mktemp -d)
probe="$work/gatekeeper-probe"
cc -o "$probe" packaging/gatekeeper-probe.c || die "cannot build the Gatekeeper probe"

tmp="$work/zip"
ditto -x -k "$zip" "$tmp"
xattr -w -r com.apple.quarantine "0083;00000000;Safari;$(uuidgen)" "$tmp/ttfx.saver"
xcrun stapler validate "$tmp/ttfx.saver" >/dev/null || die "staple validation failed"
spctl --assess --type install --context context:primary-signature -vv "$tmp/ttfx.saver" 2>&1 \
  | grep -q "source=Notarized Developer ID" \
  || die "Gatekeeper did not accept the notarized bundle"
# spctl answers "would this be allowed to open". Nothing ever opens a screen
# saver: legacyScreenSaver dlopen's it, through a second gate spctl does not
# consult. That gate is what produces "Apple could not verify ttfx.saver is
# free of malware", so it is the one worth asking. A release passed every
# check above and still hit it.
"$probe" "$tmp/ttfx.saver/Contents/MacOS/ttfx-saver" >/dev/null \
  || die "quarantined bundle refused by the library-load gate"
archs=$(lipo -archs "$tmp/ttfx.saver/Contents/MacOS/ttfx-saver")
echo "$archs" | grep -q arm64  || die "missing arm64 slice"
echo "$archs" | grep -q x86_64 || die "missing x86_64 slice"
echo "  zip:      stapled, notarized, loads under quarantine, universal ($archs)"

xcrun stapler validate "$pkg" >/dev/null || die "package staple validation failed"
spctl --assess --type install -vv "$pkg" 2>&1 \
  | grep -q "source=Notarized Developer ID" \
  || die "Gatekeeper did not accept the notarized package"
# The payload must carry no quarantine of its own. pkgbuild copies extended
# attributes verbatim and the installer restores them, so one picked up on the
# build tree would be stamped onto every installed file — reintroducing, from
# inside the fix, the exact thing the package exists to prevent.
pkgutil --expand-full "$pkg" "$work/expanded" >/dev/null \
  || die "cannot expand the package to inspect its payload"
if xattr -p -r com.apple.quarantine "$work/expanded" 2>/dev/null | grep -q .; then
  die "package payload carries com.apple.quarantine"
fi
echo "  package:  stapled, notarized, payload carries no quarantine"
rm -rf "$work"

if $DRY_RUN; then
  say "Dry run: stopping before publish"
  echo "  would tag:     $tag"
  echo "  would upload:  $pkg"
  echo "  would upload:  $zip"
  echo "  would set cask version=$version sha256=$pkgsha"
  exit 0
fi

# --- publish ---------------------------------------------------------------

say "Publishing the GitHub release"
# Notes are built from commit subjects rather than --generate-notes, which
# summarises merged PRs and so produces an empty changelog on a repo that
# lands work directly on main.
prev=$(git tag --sort=-creatordate | head -1)
if [ -n "$prev" ]; then
  changes=$(git log --no-merges --pretty='- %s' "$prev..HEAD")
  compare=$(cat <<EOF


**Full changelog**: https://github.com/HiroProt/ttfx-macos-screensaver/compare/$prev...$tag
EOF
)
else
  changes=$(git log --no-merges --pretty='- %s')
  compare=""
fi
# An unquoted heredoc, not a double-quoted string. The notes are prose with
# quotation marks in them, and in a "..." assignment an unescaped " silently
# ends the string and hands the rest of the paragraph to the shell as
# commands — which is exactly what happened, mid-ship, after notarization and
# before the tag:
#
#   ./ship.sh: line 187: all: command not found
#
# A heredoc still expands $variables, which this needs, but leaves quotes
# alone. Backticks are still escaped, because it would run those.
notes=$(cat <<EOF
## Changes

$changes

## Install

\`\`\`sh
brew tap HiroProt/tap
brew trust --cask HiroProt/tap/ttfx-screensaver   # Homebrew requires this for third-party taps
brew install --cask ttfx-screensaver
\`\`\`

Already installed? \`brew upgrade --cask ttfx-screensaver\`.

Or download **ttfx-screensaver-$version.pkg** below and double-click it. The
installer offers **for all users** or **for me only**; the second needs no
password. Signed, notarized and stapled, universal (Apple Silicon and Intel),
macOS 11 and later.

The \`.zip\` below is the bare bundle for anyone who prefers to place it by
hand. Prefer the package: a downloaded zip is quarantined, and a quarantined
screen saver is loaded through a Gatekeeper gate that can refuse it with
*"Apple could not verify 'ttfx.saver' is free of malware"* and no way forward
in the dialog. If you hit that, either install the package or run:

\`\`\`sh
xattr -dr com.apple.quarantine ~/Library/Screen\\ Savers/ttfx.saver
\`\`\`

Files the installer lays down are never quarantined, so the package cannot
land in that state.

\`sha256 (pkg): $pkgsha\`
\`sha256 (zip): $sha\`$compare
EOF
)

git tag -a "$tag" -m "$tag"
git push -q origin "$tag"
printf '%s' "$notes" | gh release create "$tag" "$pkg" "$zip" --title "$tag" --notes-file - >/dev/null
echo "  $(gh release view "$tag" --json url --jq .url)"

# The release must be downloadable before the cask points at it, or the
# first `brew install` after this races the CDN and 404s.
say "Confirming the published assets are downloadable"
base="https://github.com/HiroProt/ttfx-macos-screensaver/releases/download/$tag"
dl=$(mktemp -d)
for pair in "ttfx-screensaver-$version.pkg $pkgsha" "ttfx-screensaver-$version.zip $sha"; do
  name=${pair% *}
  want=${pair#* }
  i=0
  until curl -sfL -o "$dl/$name" "$base/$name" 2>/dev/null; do
    i=$((i + 1))
    [ $i -gt 12 ] && die "published asset not downloadable after 60s: $base/$name"
    sleep 5
  done
  [ "$(shasum -a 256 "$dl/$name" | cut -d' ' -f1)" = "$want" ] \
    || die "published $name sha256 does not match the local artifact"
  echo "  $name downloaded, sha256 matches"
done
rm -rf "$dl"

# --- homebrew --------------------------------------------------------------

say "Updating the Homebrew cask"
# The cask installs the package, so it is the package's checksum that goes in.
/usr/bin/sed -i '' \
  -e "s|^  version \".*\"|  version \"$version\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$pkgsha\"|" \
  "$CASK"
grep -q "version \"$version\"" "$CASK" || die "cask version did not update"
grep -q "sha256 \"$pkgsha\"" "$CASK"   || die "cask sha256 did not update"
# Guard the pairing itself: a cask left pointing at the zip would install a
# quarantined bundle again, which is the whole bug.
grep -q 'pkg "ttfx-screensaver' "$CASK" || die "cask does not install the package"
git -C "$TAP_DIR" commit -qam "ttfx-screensaver $version"
git -C "$TAP_DIR" push -q origin main
echo "  tap updated to $version"

say "Shipped $tag"
echo "  release:  $(gh release view "$tag" --json url --jq .url)"
echo "  install:  brew install --cask ttfx-screensaver"
echo "  (existing users: brew upgrade --cask ttfx-screensaver)"
