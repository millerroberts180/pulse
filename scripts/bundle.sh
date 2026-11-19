#!/bin/zsh
# Builds Pulse.app into build/: a universal release build for Apple silicon
# and Intel Macs.
#
#   scripts/bundle.sh                     signed with "Pulse Local Signing" when
#                                         scripts/signing-identity.sh has made it,
#                                         otherwise ad hoc
#   PULSE_SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh
#   PULSE_ARCHS=arm64 scripts/bundle.sh   one architecture, quicker
#
# macOS ties the Accessibility grant to the app's signature. An ad-hoc
# signature changes with every build, so each rebuild needs the permission
# granted again; a stable identity keeps it.
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

archs=(${=PULSE_ARCHS:-arm64 x86_64})
slices=()
for arch in $archs; do
  swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch"
  slices+=(".build/$arch/release/Pulse")
done

app="build/Pulse.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
# About's links, from the one place they are set. Only the bundle's copy is
# stamped; a value left empty keeps ReleaseInfo's placeholder.
source Resources/release.env
for setting in PulseWebsiteURL=WEBSITE_URL PulseSupportEmail=SUPPORT_EMAIL PulseSupportURL=SUPPORT_URL \
               PulsePrivacyPolicyURL=PRIVACY_POLICY_URL PulseEULAURL=EULA_URL; do
  variable="${setting#*=}"
  if [[ -n ${(P)variable:-} ]]; then
    plutil -replace "${setting%%=*}" -string "${(P)variable}" "$app/Contents/Info.plist"
  fi
done
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Tactile's MIT licence asks for its notice in every copy, so the notices
# ship inside the app.
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
lipo -create "${slices[@]}" -output "$app/Contents/MacOS/Pulse"
# Local symbols are only for debugging; dropping them shrinks the app ~40 %.
strip -x "$app/Contents/MacOS/Pulse"

local_name="Pulse Local Signing"
local_keychain="$HOME/Library/Keychains/pulse-signing.keychain-db"
if [[ -n ${PULSE_SIGN_IDENTITY:-} ]]; then
  # A Developer ID signature needs a secure timestamp to be notarized.
  codesign --force --options runtime --timestamp --sign "$PULSE_SIGN_IDENTITY" "$app"
elif [[ -f $local_keychain ]] && security find-certificate -c "$local_name" "$local_keychain" >/dev/null 2>&1; then
  security unlock-keychain -p pulse-local-signing "$local_keychain"
  codesign --force --options runtime --keychain "$local_keychain" --sign "$local_name" "$app"
else
  codesign --force --options runtime --sign - "$app"
  echo "Signed ad hoc. Run scripts/signing-identity.sh once to keep the Accessibility grant across builds."
fi

echo "Built $app ($(du -sh "$app" | cut -f1), $(lipo -archs "$app/Contents/MacOS/Pulse"))"
