#!/bin/sh
# Build the two distributable forms of ttfx.saver, both Developer ID signed,
# notarized and stapled. ./build.sh alone produces an ad-hoc signed bundle
# that only works on the machine that built it.
#
#   dist/ttfx-screensaver-<v>.pkg    the install everyone should use
#   dist/ttfx-screensaver-<v>.zip    the bare bundle, for people who want it
#
#   ./release.sh                     # sign only (NOT distributable yet)
#   ./release.sh --notarize          # sign, submit to Apple, staple, package
#
# Why both, when the zip alone used to be the release: a browser marks every
# download with com.apple.quarantine, and a quarantined screen saver is
# dlopen'd into legacyScreenSaver through Gatekeeper's library-load gate.
# When that gate refuses, the user sees "Apple could not verify ttfx.saver is
# free of malware" and the dialog offers no way through. Notarizing correctly
# does not remove that gate; it only makes it usually say yes. A package
# removes it: files the installer lays down carry no quarantine at all.
#
# Signing identities: override with IDENTITY / INSTALLER_IDENTITY if you have
# more than one. They are two different certificates.
#   IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
#
# Notarization credentials, in the order this script looks for them:
#
#   1. A stored keychain profile — what ship.sh uses, and what you want:
#        xcrun notarytool store-credentials ttfx-notary --apple-id ... --team-id ...
#        NOTARY_PROFILE=ttfx-notary ./release.sh --notarize
#      Omit --password there and it prompts, reading stdin, so the secret can
#      be piped in and never reaches a command line.
#   2. An Apple ID + app-specific password:
#        NOTARY_APPLE_ID=you@example.com NOTARY_TEAM_ID=TEAMID \
#        NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx ./release.sh --notarize
#      Note what this costs: notarytool takes the password as an argument, and
#      arguments are visible in `ps` to every process on the machine for as
#      long as the submission runs. Prefer 1.
#   3. An App Store Connect API key:
#        NOTARY_KEY=~/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX \
#        NOTARY_ISSUER=<issuer-uuid> ./release.sh --notarize
#      The issuer UUID is in App Store Connect → Users and Access →
#      Integrations. Only this method needs it.
set -e

here=$(cd "$(dirname "$0")" && pwd)
bundle="$here/ttfx.saver"
dist="$here/dist"

if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 \
    | sed 's/.*"\(.*\)"/\1/')
fi
[ -n "$IDENTITY" ] || {
  echo "No Developer ID Application identity found." >&2
  echo "Releases need one (Apple Developer Program). ./build.sh works without it." >&2
  exit 1
}

# The installer certificate is a separate one, and `security find-identity`
# only lists it without -p codesigning: it is not a code signing identity.
if [ -z "$INSTALLER_IDENTITY" ]; then
  INSTALLER_IDENTITY=$(security find-identity -v \
    | grep "Developer ID Installer" | head -1 \
    | sed 's/.*"\(.*\)"/\1/')
fi
[ -n "$INSTALLER_IDENTITY" ] || {
  echo "No Developer ID Installer identity found." >&2
  echo "This is a different certificate from the Application one you already" >&2
  echo "have, and the package needs it. Create it (free, same account) at" >&2
  echo "  https://developer.apple.com/account/resources/certificates/add" >&2
  echo "choosing 'Developer ID Installer', then download and double-click it." >&2
  exit 1
}

"$here/build.sh"

echo "==> signing as: $IDENTITY"
# --options runtime (hardened runtime) is required for notarization.
codesign --force --deep --timestamp --options runtime -s "$IDENTITY" "$bundle"
codesign --verify --deep --strict --verbose=1 "$bundle"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$bundle/Contents/Info.plist")
mkdir -p "$dist"
zip="$dist/ttfx-screensaver-$version.zip"
pkg="$dist/ttfx-screensaver-$version.pkg"
rm -f "$zip" "$pkg"

notarize_file() {  # <file> <notarytool credential args...>
  file=$1
  shift
  xcrun notarytool submit "$file" "$@" --wait
}

if [ "$1" = "--notarize" ]; then
  # Apple's notary service wants a zip; ditto preserves the bundle's
  # signature and symlinks the way the service expects.
  submit="$dist/notarize-input.zip"
  rm -f "$submit"
  /usr/bin/ditto -c -k --keepParent "$bundle" "$submit"

  echo "==> submitting to Apple (this usually takes a few minutes)"
  # Profile first: it is the only one of these that keeps the secret off the
  # command line, so a setup that has both should get the safe one.
  if [ -n "$NOTARY_PROFILE" ]; then
    set -- --keychain-profile "$NOTARY_PROFILE"
  elif [ -n "$NOTARY_APPLE_ID" ] && [ -n "$NOTARY_PASSWORD" ] && [ -n "$NOTARY_TEAM_ID" ]; then
    echo "==> warning: passing the password as an argument; it is visible in ps" >&2
    set -- --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" \
           --team-id "$NOTARY_TEAM_ID"
  elif [ -n "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ]; then
    set -- --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  else
    echo "Notarization needs credentials — see the header of this script." >&2
    echo "Easiest: ./ship.sh, which reads them from 1Password." >&2
    exit 1
  fi
  notarize_file "$submit" "$@"
  rm -f "$submit"

  # Staple the ticket into the bundle so it validates offline, then verify
  # the way Gatekeeper actually will.
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
  spctl --assess --type install --context context:primary-signature -vv "$bundle" 2>&1 \
    | sed 's/^/    /'
  echo "==> notarized and stapled"
  NOTARIZED=true
else
  echo "==> NOT notarized: this zip will be blocked by Gatekeeper on other Macs."
  echo "    Re-run with --notarize before publishing a release."
  NOTARIZED=false
fi

/usr/bin/ditto -c -k --keepParent "$bundle" "$zip"

# --- the installer package -------------------------------------------------
# Built from the bundle as it stands now, which after --notarize means the
# stapled one: the copy inside the package has to carry its own ticket, since
# someone can always drag it back out of /Library/Screen Savers.

echo "==> building the installer package"
pkgroot="$here/target/pkgroot"
pkgwork="$here/target/pkg"
rm -rf "$pkgroot" "$pkgwork"
mkdir -p "$pkgroot" "$pkgwork"
/usr/bin/ditto "$bundle" "$pkgroot/ttfx.saver"

# pkgbuild copies extended attributes into the payload verbatim, and the
# installer restores them. A com.apple.quarantine that reached the build tree
# — from an unzipped download, from a test — would therefore be reproduced on
# every installed file and defeat the entire reason this package exists.
# Measured, not assumed: a payload built from an unzipped release put its own
# quarantine back onto the installed bundle on a clean VM.
#
# Targeted rather than `xattr -c`, because com.apple.provenance is
# system-managed and cannot be removed: clearing everything only adds
# permission errors that read like a fault.
xattr -d -r com.apple.quarantine "$pkgroot/ttfx.saver" 2>/dev/null || true
if xattr -p -r com.apple.quarantine "$pkgroot/ttfx.saver" 2>/dev/null | grep -q .; then
  echo "payload still carries com.apple.quarantine after stripping" >&2
  exit 1
fi
# Stripping attributes must not have disturbed what makes the payload valid.
codesign --verify --deep --strict "$pkgroot/ttfx.saver"
if $NOTARIZED; then xcrun stapler validate "$pkgroot/ttfx.saver" >/dev/null; fi

# A *relative* install-location is what lets one package serve both domains:
# the installer resolves it against /, or against the home directory, per the
# destination the user (or Homebrew) picked. See packaging/pkg/distribution.xml.
if ! pkgbuild --identifier gg.ka.ttfx \
              --version "$version" \
              --root "$pkgroot" \
              --install-location "Library/Screen Savers" \
              --scripts "$here/packaging/pkg/scripts" \
              "$pkgwork/component.pkg" > "$pkgwork/pkgbuild.log" 2>&1; then
  sed 's/^/    /' "$pkgwork/pkgbuild.log" >&2
  echo "pkgbuild failed" >&2
  exit 1
fi
# "write: Permission denied" here is pkgbuild declining to copy the
# system-managed com.apple.provenance attribute into the payload. Nothing
# depends on it and the package is fine, but printed it reads like a fault,
# and a build that cries wolf is a build whose output stops being read.
grep -v '^write: Permission denied$' "$pkgwork/pkgbuild.log" | sed 's/^/    /'

sed "s/@VERSION@/$version/" "$here/packaging/pkg/distribution.xml" \
  > "$pkgwork/distribution.xml"
grep -q "version=\"$version\"" "$pkgwork/distribution.xml" \
  || { echo "distribution.xml did not pick up version $version" >&2; exit 1; }

productbuild --distribution "$pkgwork/distribution.xml" \
             --package-path "$pkgwork" \
             "$pkgwork/unsigned.pkg" >/dev/null
productsign --sign "$INSTALLER_IDENTITY" "$pkgwork/unsigned.pkg" "$pkg" >/dev/null
pkgutil --check-signature "$pkg" | sed 's/^/    /'

if $NOTARIZED; then
  # The package is its own downloadable thing, so it needs its own ticket:
  # the bundle's says nothing about the wrapper around it.
  echo "==> submitting the package to Apple"
  notarize_file "$pkg" "$@"
  xcrun stapler staple "$pkg"
  xcrun stapler validate "$pkg"
  spctl --assess --type install -vv "$pkg" 2>&1 | sed 's/^/    /'
fi

echo
echo "release artifacts:"
for f in "$pkg" "$zip"; do
  printf '  %s\n  sha256: %s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
done
