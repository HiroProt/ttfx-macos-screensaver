#!/bin/sh
# Ship a release, end to end:
#
#   preflight → build + sign + notarize + staple → GitHub release →
#   verify the published download the way a stranger's Mac will →
#   bump the Homebrew cask → push the tap
#
#   ./ship.sh              # ship the version in Resources/Info.plist
#   ./ship.sh --dry-run    # do everything except publish and push
#
# Credentials come from 1Password so nothing secret lives on disk or in
# shell history. Override the item with NOTARY_OP_ITEM if you move it.
# Requires: op (signed in), gh (authenticated), a Developer ID identity.
set -e

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

DRY_RUN=false
[ "$1" = "--dry-run" ] && DRY_RUN=true

# Plain ASCII on purpose: op secret references reject characters like an
# em-dash in the item title.
NOTARY_OP_ITEM=${NOTARY_OP_ITEM:-"op://23made/Apple Notarization 23made"}
TAP_DIR=${TAP_DIR:-"$HOME/Projects/homebrew-tap"}
CASK=$TAP_DIR/Casks/ttfx-screensaver.rb

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
# Everything that can be checked before doing irreversible work, is.

say "Preflight"
command -v op >/dev/null || die "1Password CLI (op) not installed"
command -v gh >/dev/null || die "GitHub CLI (gh) not installed"
op account list >/dev/null 2>&1 || die "op is not signed in — run: eval \$(op signin)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "no Developer ID Application identity in the keychain"

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
# Read into the environment only; never echoed, never written to disk.

say "Reading notarization credentials from 1Password"
NOTARY_APPLE_ID=$(op read "$NOTARY_OP_ITEM/username") || die "cannot read Apple ID"
NOTARY_PASSWORD=$(op read "$NOTARY_OP_ITEM/password") || die "cannot read app-specific password"
NOTARY_TEAM_ID=$(op read "$NOTARY_OP_ITEM/Team ID") || die "cannot read Team ID"
export NOTARY_APPLE_ID NOTARY_PASSWORD NOTARY_TEAM_ID
echo "  apple id: $NOTARY_APPLE_ID"
echo "  team id:  $NOTARY_TEAM_ID"
echo "  password: (read from 1Password, not shown)"

# --- build, sign, notarize -------------------------------------------------

say "Building and notarizing"
./release.sh --notarize

zip="dist/ttfx-screensaver-$version.zip"
[ -f "$zip" ] || die "expected artifact missing: $zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
echo "  artifact: $zip"
echo "  sha256:   $sha"

# Prove the ticket survived zipping and that Gatekeeper accepts the bundle
# with the quarantine flag a browser download would attach. Catching this
# here beats catching it in someone's bug report.
say "Verifying the artifact as a downloader would see it"
tmp=$(mktemp -d)
ditto -x -k "$zip" "$tmp"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$tmp/ttfx.saver"
xcrun stapler validate "$tmp/ttfx.saver" >/dev/null || die "staple validation failed"
spctl --assess --type install --context context:primary-signature -vv "$tmp/ttfx.saver" 2>&1 \
  | grep -q "source=Notarized Developer ID" \
  || die "Gatekeeper did not accept the notarized bundle"
archs=$(lipo -archs "$tmp/ttfx.saver/Contents/MacOS/ttfx-saver")
echo "$archs" | grep -q arm64  || die "missing arm64 slice"
echo "$archs" | grep -q x86_64 || die "missing x86_64 slice"
rm -rf "$tmp"
echo "  stapled, notarized, universal ($archs)"

if $DRY_RUN; then
  say "Dry run: stopping before publish"
  echo "  would tag:     $tag"
  echo "  would upload:  $zip"
  echo "  would set cask version=$version sha256=$sha"
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
  compare="

**Full changelog**: https://github.com/HiroProt/ttfx-macos-screensaver/compare/$prev...$tag"
else
  changes=$(git log --no-merges --pretty='- %s')
  compare=""
fi
notes="## Changes

$changes

## Install

\`\`\`sh
brew install --cask ttfx-screensaver     # new
brew upgrade --cask ttfx-screensaver     # existing
\`\`\`

Or download the zip below, unzip, and double-click \`ttfx.saver\`. Signed,
notarized and stapled, so there's no Gatekeeper prompt. Universal (Apple
Silicon and Intel), macOS 11 and later.

\`sha256: $sha\`$compare"

git tag -a "$tag" -m "$tag"
git push -q origin "$tag"
printf '%s' "$notes" | gh release create "$tag" "$zip" --title "$tag" --notes-file - >/dev/null
echo "  $(gh release view "$tag" --json url --jq .url)"

# The release must be downloadable before the cask points at it, or the
# first `brew install` after this races the CDN and 404s.
say "Confirming the published asset is downloadable"
url="https://github.com/HiroProt/ttfx-macos-screensaver/releases/download/$tag/ttfx-screensaver-$version.zip"
dl=$(mktemp -d)
i=0
until curl -sfL -o "$dl/x.zip" "$url" 2>/dev/null; do
  i=$((i + 1))
  [ $i -gt 12 ] && die "published asset not downloadable after 60s: $url"
  sleep 5
done
[ "$(shasum -a 256 "$dl/x.zip" | cut -d' ' -f1)" = "$sha" ] \
  || die "published asset sha256 does not match the local artifact"
rm -rf "$dl"
echo "  downloaded and sha256 matches"

# --- homebrew --------------------------------------------------------------

say "Updating the Homebrew cask"
/usr/bin/sed -i '' \
  -e "s|^  version \".*\"|  version \"$version\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$sha\"|" \
  "$CASK"
grep -q "version \"$version\"" "$CASK" || die "cask version did not update"
grep -q "sha256 \"$sha\"" "$CASK"     || die "cask sha256 did not update"
git -C "$TAP_DIR" commit -qam "ttfx-screensaver $version"
git -C "$TAP_DIR" push -q origin main
echo "  tap updated to $version"

say "Shipped $tag"
echo "  release:  $(gh release view "$tag" --json url --jq .url)"
echo "  install:  brew install --cask ttfx-screensaver"
echo "  (existing users: brew upgrade --cask ttfx-screensaver)"
