#!/bin/sh
# Build a distributable ttfx.saver: Developer ID signed, notarized, stapled,
# zipped. The result installs by double-click on any Mac with no Gatekeeper
# warning; ./build.sh alone produces an ad-hoc signed bundle that only works
# on the machine that built it.
#
#   ./release.sh                     # sign only (zip is NOT distributable yet)
#   ./release.sh --notarize          # sign, submit to Apple, staple, zip
#
# Signing identity: override with IDENTITY=... if you have more than one.
#   IDENTITY="Developer ID Application: Your Name (TEAMID)"
#
# Notarization credentials, in the order this script looks for them:
#
#   1. An Apple ID + app-specific password (no issuer UUID needed):
#        NOTARY_APPLE_ID=you@example.com NOTARY_TEAM_ID=TEAMID \
#        NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx ./release.sh --notarize
#      ship.sh pulls exactly these out of 1Password for you.
#   2. A stored keychain profile:
#        xcrun notarytool store-credentials ttfx-notary ...
#        NOTARY_PROFILE=ttfx-notary ./release.sh --notarize
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

"$here/build.sh"

echo "==> signing as: $IDENTITY"
# --options runtime (hardened runtime) is required for notarization.
codesign --force --deep --timestamp --options runtime -s "$IDENTITY" "$bundle"
codesign --verify --deep --strict --verbose=1 "$bundle"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$bundle/Contents/Info.plist")
mkdir -p "$dist"
zip="$dist/ttfx-screensaver-$version.zip"
rm -f "$zip"

if [ "$1" = "--notarize" ]; then
  # Apple's notary service wants a zip; ditto preserves the bundle's
  # signature and symlinks the way the service expects.
  submit="$dist/notarize-input.zip"
  rm -f "$submit"
  /usr/bin/ditto -c -k --keepParent "$bundle" "$submit"

  echo "==> submitting to Apple (this usually takes a few minutes)"
  if [ -n "$NOTARY_APPLE_ID" ] && [ -n "$NOTARY_PASSWORD" ] && [ -n "$NOTARY_TEAM_ID" ]; then
    set -- --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" \
           --team-id "$NOTARY_TEAM_ID"
  elif [ -n "$NOTARY_PROFILE" ]; then
    set -- --keychain-profile "$NOTARY_PROFILE"
  elif [ -n "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ]; then
    set -- --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  else
    echo "Notarization needs credentials — see the header of this script." >&2
    echo "Easiest: ./ship.sh, which reads them from 1Password." >&2
    exit 1
  fi
  xcrun notarytool submit "$submit" "$@" --wait
  rm -f "$submit"

  # Staple the ticket into the bundle so it validates offline, then verify
  # the way Gatekeeper actually will.
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
  spctl --assess --type install --context context:primary-signature -vv "$bundle" 2>&1 \
    | sed 's/^/    /'
  echo "==> notarized and stapled"
else
  echo "==> NOT notarized: this zip will be blocked by Gatekeeper on other Macs."
  echo "    Re-run with --notarize before publishing a release."
fi

/usr/bin/ditto -c -k --keepParent "$bundle" "$zip"
echo "release artifact: $zip"
shasum -a 256 "$zip" | sed 's/^/sha256: /'
