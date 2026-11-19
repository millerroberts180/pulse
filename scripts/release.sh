#!/bin/zsh
# Builds Pulse for distribution: universal, signed with a Developer ID,
# notarized by Apple, stapled, and zipped into build/Pulse-<version>.zip.
#
#   PULSE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   PULSE_NOTARY_PROFILE=pulse-notary scripts/release.sh
#
# Store the notary credentials once (an app-specific password from
# appleid.apple.com):
#   xcrun notarytool store-credentials pulse-notary \
#     --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

: "${PULSE_SIGN_IDENTITY:?Set PULSE_SIGN_IDENTITY to a Developer ID Application identity}"
: "${PULSE_NOTARY_PROFILE:?Set PULSE_NOTARY_PROFILE to a notarytool keychain profile}"
[[ $PULSE_SIGN_IDENTITY == "Developer ID Application:"* ]] || { echo "Notarization needs a Developer ID Application identity"; exit 1; }

# About's links would otherwise lead to placeholders.
source Resources/release.env
unset_links=()
for variable in WEBSITE_URL SUPPORT_EMAIL PRIVACY_POLICY_URL EULA_URL; do
  [[ -n ${(P)variable:-} ]] || unset_links+=($variable)
done
(( ${#unset_links} == 0 )) || { echo "Set ${unset_links[*]} in Resources/release.env first"; exit 1; }

scripts/test.sh
PULSE_SIGN_IDENTITY="$PULSE_SIGN_IDENTITY" scripts/bundle.sh

app="build/Pulse.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
upload="build/Pulse-$version-notarize.zip"
ditto -c -k --keepParent "$app" "$upload"
xcrun notarytool submit "$upload" --keychain-profile "$PULSE_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
rm "$upload"

zip="build/Pulse-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
spctl --assess --type execute --verbose "$app"
echo "Ready to share: $zip"
