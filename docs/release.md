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
unfinished: one where the website, privacy policy or licence agreement link in
`Resources/release.env` is empty, or both `SUPPORT_EMAIL` and `SUPPORT_URL`
are.

## Links

`Resources/release.env` sets where Pulse points people from Settings › About:
the website, support, the privacy policy and the licence agreement.
`bundle.sh` stamps each value that is set onto the bundle's Info.plist. An
empty one falls back to a placeholder on pulse.example, so a test build still
has somewhere to point. Pulse opens these only when someone clicks one. The
privacy policy and licence agreement point to their drafts in `docs/legal` on
GitHub.

Support is an email address (`SUPPORT_EMAIL`), a help page (`SUPPORT_URL`),
or both. The Support link opens the page when there is one, and otherwise an
email. It shows the address when there is one, otherwise the page's host, as
the Website link shows its host. I set only `SUPPORT_URL`, to the GitHub
issues, so About shows `github.com` and Pulse publishes no email address.

Drafts of the two legal pages are in [legal](legal). Neither has been reviewed
by a lawyer; fill in the bracketed parts and have them checked before
publishing them.
