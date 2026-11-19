# Development

## Build, run, test

Requires macOS 14+ and the Swift 6.2 toolchain (the Command Line Tools are
enough).

```sh
scripts/signing-identity.sh   # once per Mac: a local signing identity
scripts/bundle.sh             # builds build/Pulse.app, universal (≈2.5 MB)
open build/Pulse.app          # opens the setup on first launch
scripts/test.sh               # unit tests (Swift Testing)
```

macOS ties the Accessibility grant to the app's signature. An ad-hoc
signature changes on every build, so the permission would need granting again
after each rebuild. `signing-identity.sh` creates a self-signed "Pulse Local
Signing" certificate in its own keychain, and `bundle.sh` signs with it
whenever it exists, so the grant survives rebuilds. `PULSE_ARCHS=arm64` builds
one architecture.

## Checks

```sh
swift build && .build/debug/Pulse --self-test        # pipelines with simulated input
.build/debug/Pulse --snapshot-ui <folder>            # every setup step and settings pane, light and dark
build/Pulse.app/Contents/MacOS/Pulse --diagnose      # actuator, sound bank, motion timing
build/Pulse.app/Contents/MacOS/Pulse --probe         # what Pulse sees under the pointer
```

- `--self-test` (debug builds) drives motion, the page detector, the setup's
  tour, the on-screen keyboard and the other-audio rule with simulated input,
  muted and off screen.
- `--snapshot-ui` (debug builds) renders the windows off screen as PNGs,
  drawn as the window in front; the screenshots in `docs/images` come from
  it. The README's hero is `hero-cues-*`: the cues step without the empty
  band above its footer. The setup images there are scaled to 1400 pixels
  wide (`sips --resampleWidth 1400`). Delete its settings afterwards with
  `defaults delete pulse.snapshots`.
- `--probe` and `--diagnose` need a terminal with Accessibility access.
  `--probe` waits three seconds, then reports whether the front page is
  Page-aware, how many headings it exposes near the viewport, and its scroll
  edges. It prints kinds and counts, never text.
- `--dump-sounds <folder>` (debug builds) writes every sound as WAV.

## Releasing

To share Pulse with other people, sign with a Developer ID and notarize:

```sh
PULSE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
PULSE_NOTARY_PROFILE=pulse-notary scripts/release.sh   # build/Pulse-<version>.zip
```

It refuses to build until the links in `Resources/release.env` are set.
[Releasing](release.md) covers them.

## Layout

```
Sources/PulseCore   pure logic, unit tested: cue vocabulary, element classifier,
                    control identity, heading and boundary trackers, motion
                    model, key interpretation, profiles, quiet rules, sound
                    synthesis and keyboard boards
Sources/Pulse       the app: event taps, Accessibility worker, haptic output,
                    audio mixer, menu bar, setup and settings windows
Tests               Swift Testing suites for PulseCore
docs                details, architecture, browser coverage, releasing, legal
                    drafts, screenshots
design/logo         logo masters, exports, and usage guide
scripts             build, test, signing, release, and fitting the boards
```

The icon and menu-bar mark are drawn in `PulseLogo.swift`;
`scripts/make-icon.sh` regenerates `Resources/AppIcon.icns` from it. The logo
masters and usage guide are in [design/logo](../design/logo). How it all
works, and why: [architecture](architecture.md).
