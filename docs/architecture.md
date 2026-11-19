# Pulse architecture

Pulse builds on what has already been shown to work rather than starting from
scratch. Where a decision came from elsewhere, it says so: mostly Tactile (open
source, MIT), whose page-detection heuristics Pulse adapts (see
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)), and Mechvibes' own
Cherry MX recordings (MIT), which the keyboard boards are measured from (never
shipped).

## Principles turned into mechanisms

| Principle | Mechanism |
| --- | --- |
| One action, one cue | `HapticOutput` drops a cue landing within 120 ms of a higher-priority one; `ControlMemory` makes one visual control cue once even when web pages re-render it; hover and selection cues are one pulse each |
| Silence is a feature | Hover cues only on *entering* a control by moving the pointer; content scrolling under a still pointer is remembered silently; headings deeper than h3 never cue; landmark cues ≥ 350 ms apart; scrolling below the motion threshold is silent |
| Learnable, not cryptic | An interactive setup (a tour page, then every cue in a line to feel and choose), and Settings › Cues as the legend afterwards |
| Comfort is mandatory | Strength, motion threshold and intensity, two volumes, and haptics-only, audio-only, or both |
| Meaning before spectacle | Five page cues, each tied to one Accessibility fact (role, selection, invalid/alert, heading position, scroll position) |
| Respect private contexts | Secure Event Input silences keys in password fields; microphone in use, other audio playing, excluded apps, mute hotkey, VoiceOver default |
| Lightweight | Event-driven, and nothing listens that isn't needed (see [Efficiency](#efficiency)); ≈2.5 MB universal app, no dependencies |

## Page detection

```
CGEventTap (listen-only, main run loop)
  ├─ pointer moves ─ 60 Hz throttle + 2 px gate + skip region ─┐
  ├─ scrolls ─ direction, gesture start, 8 Hz probe + trailing ┤
  │    └─ speed ─ MotionModel ─ glide / swell (no queries) ─────┼─▶ cue
  └─ clicks ─ forget geometry, re-resolve after 150 ms ────────┤
AXObserver on the frontmost app: focus, selection, live regions┤
  + with waypoints on: find-bar selection and announcements ───┤
                                                               ▼
AXWorker (one serial background queue, latest-wins, 50 ms per message)
  hover: element at point → classify → recover the real control
         (ancestor for labels, descendant for padding, specific
          control inside a wrapper) → size sanity → destructive check
         inert results cached 1 s (leaves; containers by child frames)
  probe: the window under the pointer (not necessarily the frontmost app)
         → scroll context (nearest AXScrollArea, AXWebArea; cached 1 s)
         → edges from the scroll bar value or document-vs-viewport frames
         → visible headings via AXUIElementsForSearchPredicate
            (AXHeadingSearchKey), starting 15 % down, below sticky headers
         → posts and articles: AXArticleSearchKey (WebKit, Gecko) or the
            articles among AXLandmarkSearchKey results (Chromium), the
            same way, once a page is known to have any; they feed the
            heading tracker, so a post and its title cue once
         → with waypoints on: highlights (AXHighlightedSearchKey), the
            same way, once a page is known to have any
                                                               ▼
PageDetector (main): ControlMemory, LandmarkTracker ×2 (headings,
                     highlights), BoundaryTracker, MotionModel → Cue
```

- **From Tactile**: the listen-only tap (NSEvent monitors miss events inside
  menu tracking loops), the three sampling gates, latest-wins background
  queries with short messaging timeouts, the role table, control-size sanity
  (≤ 900×350 pt), fragment/wrapper recovery, IoU ≥ 0.6 identity, and never
  hit-testing Pulse's own process off the main thread.
- **Beyond Tactile**: attributes fetched with
  `AXUIElementCopyMultipleAttributeValues` (one message instead of five);
  heading landmarks through the same search VoiceOver's rotor uses (WebKit and
  Chromium both implement it), so no extension is needed; boundary and
  selection cues; passive-scroll suppression.
- **Page ends in Gecko**: Firefox and Zen report the web area at the
  viewport's size, which reads as "fits, at both ends". There Pulse takes the
  document's extent from the web area's first and last children (usually one
  group, the page body), several at each end so a fixed banner can't pass for
  the end of the page.
- **Pulse's own windows** are skipped only where one is actually in front
  (`NSWindow.windowNumber(at:)`); one hidden behind another app's window
  doesn't silence that part of the screen.
- **Page-aware vs Motion-only** is decided per app by whether the scrolled
  region contains a web area that answers heading searches.

## Haptics

Cues play through the public `NSHapticFeedbackManager`: on current macOS the
private actuator calls can report success without a perceptible pulse. Each
cue's pulses map to the three public patterns, stepped up at the stronger
strength settings. With only three strengths, a sequence of pulses reads as a
double or triple click rather than a ripple, so every hover, selection,
heading, and motion cue is one pulse, told apart by strength: links light,
controls firmer, glides the faintest. Only three cues have two pulses, each
with its own rhythm: caution (two equal strong pulses, 95 ms apart),
boundary (strong, then faint), waypoint (light, then firmer: rising).
Minimum gap between cues: 20 ms.

`HapticOutput.play` applies the one-cue policy even when haptics are off or
the cue is heard only, so a cue's sound stands in for it under the same rules
(audio-only mode, momentum glides).

`ActuatorDriver` (MultitouchSupport via `dlopen`, Gaussian pulses through
`MTActuationCreateFromDictionary`) is kept for `--diagnose` and future
hardware-validated shapes. MultitouchSupport is a private framework, so any
macOS update can change or remove it; if a call is missing, the driver isn't
made and the public API plays instead. It is never loaded at launch.

`ReleaseClick` makes a physical click a single haptic. The trackpad firmware
plays its own press and release clicks from two HID feature reports (0x22 and
0x23, read and written with `MTActuatorGetReport` / `MTActuatorSetReport`).
The release report on a MacBook Pro is one pulse, `[1, amplitude, duration]` =
`01 12 a8`; Pulse writes `01 00 a8` and checks it reads back. The original is
saved in user defaults before the write and restored at quit (including
SIGTERM/SIGINT/SIGHUP), on mute or haptics off, or at the next launch after a
force quit with the setting off. Only that exact single-pulse form is ever
changed (`ClickWaveform`). While silenced, a 30 s timer and wake re-read the
report, because the system can resend its clicks.

**All cue shapes are first guesses and must be tuned on hardware.**

## Motion scrolling

`MotionModel` (PulseCore) follows speed with an exponential follower (35 ms)
of |Δ|/Δt over each event's own timestamp, so events queued behind a busy main
thread don't read as a burst. A pause over 150 ms or a change of direction
starts over; a new swipe doesn't, so repeated swipes keep a fast scroll
gliding.

| Phase | Response |
| --- | --- |
| Below the threshold (550 / 850 / 1400 pt/s) | Silence |
| Crossing it | Motion begins; the first glide waits one interval, so it builds |
| A burst: ≥ 1.8 × threshold and ≥ 1.6 × the speed 150 ms earlier | One swell (cooldown 0.8 s); the first glide follows 80 ms later (the one-cue rule lets a glide follow a swell) |
| Sustained | Glides every 160 ms at the threshold down to 70 ms at 4 × (eased), softer (sound level 1 → 0.6) as they close up |
| Slowing | Intervals stretch again; below 0.7 × threshold, silence |
| Page end | `hold()`: nothing more until the next swipe, including the rubber-band bounce. Content that fits has no end to stop at |

Spacing is in time, not distance, so a fling feels like a flywheel rather than
a ratchet. Haptics play only while fingers are down (phase set, no momentum
phase); momentum and mouse wheels are heard only. `Pulse --diagnose` prints
the pulse timeline of a typical fling at each threshold.

## Waypoints

Off until switched on in Settings › Cues. Two signals, both measured in
[browser-coverage.md](browser-coverage.md):

- **Find-in-page matches.** Safari moves the page's selection to the match;
  Chromium announces "Result n of m". A second observer (with notification
  details) listens for just those two notifications, and the worker checks
  that the browser's own find field has focus (a text field with no web area
  above it) before cueing. The announcement is read only for its two numbers.
  Firefox posts neither.
- **Highlighted text** (`<mark>`) crossing the reading line, through
  `AXHighlightedSearchKey` (WebKit). Chromium answers that unknown key with
  every element; the first such answer marks the app unsupported. A search
  for something a page doesn't have walks the whole document, so whether a
  page has any highlights is checked once per page every 5 s.

Unread markers, comments, and saved places have no standard accessibility
semantics, so they are left to a future integration rather than guessed.

## Quiet rules

`MediaMonitor` uses Core Audio's per-process objects (macOS 14.2+), as Tactile
does. "Is running output" posts no notification itself; "is running" does,
whenever a process starts or stops audio I/O, so Pulse listens to that and
reads the output flag. Playing must last 1.2 s to count and silence 2.5 s to
end, so alerts and the gap between tracks don't flicker. Pulse's own process,
system sounds, and speech (VoiceOver, speech synthesis) are ignored
(`QuietRules`). It quiets keyboard, page, and motion sounds; haptics continue.

## Setup and settings

SwiftUI windows, created on demand and held while Pulse runs.

- **Tour**: an AppKit scroll view inside a drawn browser frame. Each section
  plays its cue as its top crosses the cue line (a third of the way down,
  where live headings cue) in either direction, and flashes the element it
  belongs to. Links and buttons also cue on hover, silent for 0.3 s after a
  scroll as on live pages; the tab strip advances as it arrives. A stretch of
  placeholder cards is for flicking (MotionModel), and the bottom is the page
  end (BoundaryTracker). A cue counts as felt on the checklist only if a
  finger was down: momentum is travel you can't feel.
- **Cue picker**: every cue in a line. A pad plays its cue as the pointer
  enters it; the glide pad plays one faint pulse per 14 pt of travel, at
  least 70 ms apart, so it feels like the glide's texture. Each switch maps
  to its own setting (links and controls, and glide and swell, are separate).
  Settings › Cues is the legend afterwards: each cue's icon plays it on
  hover, beside its meaning and switch, in a window narrow enough to sit
  beside a browser.

- **Typing**: an on-screen US Mac keyboard. A local event monitor (only
  while the setup window is in front) and clicks feed the same
  `KeyInterpreter` and `KeyboardVoicing` as live typing, so chords, Caps
  Lock, and repeats sound as they will; only key codes are used, to light the
  key and pick its group. It listens only while its own window is key; then
  the live keyboard engine is silenced so nothing plays twice, and keys other
  than ⌘ shortcuts stay in the demo. Settings › Keyboard has a smaller copy.
- **Re-runs** (Settings › General › Open Tutorial…) show only the tutorial
  steps: tour, cues, typing.

Settings' choices (strength, where motion starts, its intensity) are drawn
tiles rather than segmented controls: a pulse's height, a silent stretch
then glide dots, dot density. Picking one plays it: a control's tick at that
strength, or a fling run through the motion model with that tuning.

Both work before Accessibility is granted, and the live detectors skip
Pulse's own windows. Previews ignore mute and the per-cue switches: feeling a
cue is how it's learned. A caption names each cue as it plays, as its visual
equivalent.

## Keyboard

```
CGEventTap (listen-only) on its own userInteractive thread
  → KeyInterpreter (group, chord, Caps Lock, repeats; no characters)
  → KeyboardVoicing (Ambient / Mechanical / KeySense / Quiet)
  → Mixer.enqueue (os_unfair_lock, never held by the render thread)
AVAudioSourceNode render callback: try-lock to take triggers, mix ≤ 12 voices
from one preloaded PCM bank, drop triggers older than 120 ms
```

The path is built for low latency: no main-thread hop, no allocation per key,
no decoding, one mixer node. The remaining floor is the output device's I/O
buffer (≈10 ms at the default size), left untouched for now so other apps
aren't affected.

Mechanical and Ambient keys are resynthesised from measured boards
(`Boards.swift`). Black, Red, Brown and Blue are measured from Mechvibes' own
recordings of Cherry MX Black, Red, Brown and Blue switches on ABS keycaps,
which its owner recorded and its MIT licence covers (the pinned commit is in
`scripts/boards/README.md`, the notice in `THIRD_PARTY_NOTICES.md`). The
recordings were measured, never shipped. Red is the default because, of the
two linears, it measures darker and shorter: its letter keys' spectral
centroid is 2.7 kHz to Black's 3.4 kHz, 3 % of their energy comes after the
first 10 ms to Black's 4 %, and 20–30 ms after the strike they are 2–5 dB
quieter. It is also the darkest of the four, so it is the nearest to the
soft, muted, short sound Pulse had by default before. For each key group a
board stores the level of 21 third-octave noise bands (100 Hz–10 kHz) at 17
moments in the first 140 ms, plus how narrow its low bands may be. Wide low
bands stop quickly, like a short thock; narrow ones ring, like a metal case. Each band's own noise is
shaped by those levels and only then band-passed (two stages), so a quick low
thock stays low instead of splattering into the mids. Noise, not tones:
real keystrokes are many tiny resonances blurred together, and the earlier
modal synthesis's pure tones at 1.2–2.5 kHz rang like metal (spectral flatness
0.004, where the recordings' key groups measure 0.14–0.62, Red's the most
tonal; a test now holds every board above 0.1). Four takes per group come
from fresh noise; release strokes are quicker and lighter in the low end.

`scripts/boards/fit.py` fits the levels to the references. It matches the
third-octave spectra of the strike (first 6 ms) and the tail (to 60 ms) and
the decay in 2 ms frames, makes
any extra brightness above 2.5 kHz cost in full, and picks each group's low
width (150, 80 or 30 Hz). Measured this way the Red board's letter keys are
within about 2 dB of the recording across the third-octave bands, in the
strike and the tail alike (2.1 and 1.5 dB), and as bright on top (24 % of
their energy above 3 kHz, the recording's 22 %). Its other key groups are
within 1.3–3.1 dB in the tail and 2.3–5.1 dB in the strike, the space bar's
and Delete's strikes the furthest off. Every board's figures are in
`scripts/boards/README.md`. `Pulse --dump-sounds <folder>`
(debug builds) writes every voice as WAV.

KeySense cues are short raised-cosine tones. Real recordings can replace any
voice through `SoundBank` without touching the pipeline.

The setup and Settings › Keyboard each have an on-screen keyboard (see Setup
and settings) that plays keys through the same interpreter and voicing.

## Line Apps

Line Apps (its own repository, `line-apps`) is the bundle's menu-bar line: a
click collapses the family's icons into it. `LineAppsFold`
(`Sources/Pulse/App/LineAppsFold.swift`, the same file in Tuck, Hum and Glow;
the line-apps copy, `Shared/LineAppsFold.swift`, is the one to change first)
hears its distributed notifications (`com.millerroberts.lineapps.fold` and
`.unfold`) and sets the status item's `isVisible` from `MenuController`,
fading the button a moment after the line moves, the nearer the line the
sooner.

- **Places.** macOS forgets a hidden item's place and brings it back at the
  far left, so the fold notes `NSStatusItem Preferred Position <autosave
  name>` as the item goes and writes it back just before it shows. Quitting
  while collapsed writes it back too, so Pulse reopens in its place.
- **Reopen.** Opening Pulse again, from Finder or the line's menu, opens
  Settings: the way in while the icon is in the line.
- **Only while Line Apps runs.** The state (`folded` in Line Apps' defaults)
  is read at launch only if Line Apps is running, and Line Apps terminating
  brings the icon back.
- **Cost.** Three notification observers, and a fourth only while collapsed.
  Detection, haptics and sounds are untouched.

## Efficiency

Pulse should cost nothing when nothing is happening, and very little when it is.

| State | What runs |
| --- | --- |
| Muted, haptics off, or excluded app | No pointer tap, no Accessibility observer, no queries |
| Hover cues off (controls and cautions) | No mouse-move events at all; scroll only if heading or boundary cues are on |
| Keyboard sound off, Quiet profile, or muted | No key tap, no Core Audio listeners |
| Every sound off | No `AVAudioEngine` is ever created; no audio hardware touched |
| Sounds on but idle 60 s | Engine stops; restarts on the next key |
| MultitouchSupport | Loaded only while the release click is silenced (one HID read per trackpad every 30 s), or by `--diagnose` |
| Motion scrolling | Arithmetic on scroll events already received; no Accessibility queries |
| Waypoints off (the default) | No find observer, no highlight searches |
| No sound can play | No Core Audio process listeners; otherwise listeners only, no polling |

Hot paths, measured with `Pulse --diagnose` and `--probe` on an M-series Mac:

| Path | Cost |
| --- | --- |
| Audio render callback | 0.03 µs idle, 0.25 µs with four overlapping keys, per 10.7 ms buffer (≈0.003 %); silent buffers are flagged so Core Audio skips mixing |
| Sound bank | 31 voices, 272 KB, rendered in 1.4 ms (one take per voice) |
| Hover query, cold | ≈20–30 ms when recovering a control from a container (budget-capped) |
| Hover query, warm (same element) | ≈0.5 ms: one message, the rest from cache |

Other measures: pointer samples reuse the event's own location (no `CGEvent`
allocation per move); trailing-sample and probe timers are created once and
re-armed; drags are ignored; live-region bursts are inspected at most twice a
second and selection changes one at a time; an app that stops answering gets
a 0.5 s backoff; settings are written once a slider settles; per-app state is
dropped when the app quits.

## Next steps

1. **Tune on a Force Touch trackpad**: cue strengths, the motion thresholds
   and spacing, the reading line (one third down), and probe rate.
2. **User testing** with people who rely on reduced visual attention and with
   VoiceOver users, before claiming an accessibility benefit.
3. **Distribution**: a Developer ID and notarization (`scripts/release.sh`).
