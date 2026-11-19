# Releasing

## Signing and notarizing

To share Pulse with other people, sign it with a Developer ID and notarize it:

```sh
PULSE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
PULSE_NOTARY_PROFILE=pulse-notary scripts/release.sh   # build/Pulse-<version>.zip
```

Store the notary credentials once, with an app-specific password from
appleid.apple.com:

```sh
xcrun notarytool store-credentials pulse-notary \
  --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
```

Before it builds anything, `release.sh` refuses a release that would ship
unfinished: one where any link in `Resources/release.env` except
`SUPPORT_URL` is empty.

## Links

`Resources/release.env` sets where Pulse points people from Settings › About:
the website, support, the privacy policy and the licence agreement.
`bundle.sh` stamps each value that is set onto the bundle's Info.plist. An
empty one falls back to a placeholder on pulse.example, so a test build still
has somewhere to point. Pulse opens these only when someone clicks one.

Drafts of the two legal pages are in [legal](legal). Neither has been reviewed
by a lawyer; fill in the bracketed parts and have them checked before
publishing them.
