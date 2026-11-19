# Keyboard boards

Pulse's Mechanical and Ambient typing sounds are resynthesised from measured descriptions
of real keyboards. Nothing recorded ships: for each key group the fitter
finds how loud 21 third-octave noise bands should be at 17 moments in the
first 140 ms, and Pulse plays fresh noise through the same bands, shaped the
same way.

| Board | Measured from (Mechvibes, MIT; none of its audio is included) |
| --- | --- |
| Black | `soundpacks/keyboard/cherrymx-black-abs` |
| Red (default) | `soundpacks/keyboard/cherrymx-red-abs` |
| Brown | `soundpacks/keyboard/cherrymx-brown-abs` |
| Blue | `soundpacks/keyboard/cherrymx-blue-abs` |

The packs are Mechvibes' own recordings of Cherry MX switches on ABS keycaps,
from https://github.com/hainguyents13/mechvibes at commit
`16afce45bd7cf12be399e2d1a8d20f221067f534`. Its owner recorded them and says
the repository's MIT licence covers the recordings
([issue #120](https://github.com/hainguyents13/mechvibes/issues/120)); the
notice is in `THIRD_PARTY_NOTICES.md`. I use only these four, not the PBT
packs or the others, which that statement doesn't clearly cover.

To re-derive `Sources/PulseCore/BoardRecipeData.swift`, download each pack's
`config.json` and `sound.ogg` at that commit into a folder of its own, convert
the audio with `afconvert -f WAVE -d LEI16@48000 -c 1 sound.ogg sound.wav`,
then:

```sh
cd scripts/boards
python3 fit.py '{"black": "/path/cherrymx-black-abs", "red": "/path/cherrymx-red-abs", "brown": "/path/cherrymx-brown-abs", "blue": "/path/cherrymx-blue-abs"}' recipes.json
python3 gen_swift.py recipes.json ../../Sources/PulseCore/BoardRecipeData.swift
```

The fitter renders exactly as Pulse does: each band's noise is shaped first,
then band-passed. It corrects the levels until the result matches the
reference in three ways: each band's shape over time, the third-octave
spectrum of the strike (first 6 ms) and of the tail (to 60 ms), and the decay
in 2 ms frames. Extra brightness
above 2.5 kHz counts in full, for gentleness. It also picks how narrow each
group's low bands may be: 150 Hz for a quick thock, down to 30 Hz for a
case that rings. Loudness follows the reference, softened: each group against
its board's letter keys, and each board's letters as loud as the default
Red's. It needs numpy and takes about four minutes.

How close each board comes: the mean difference across the third-octave
bands of the strike and of the tail, for the letter keys and as a range over
all six key groups, and the letters' share of energy above 3 kHz.

| Board | Letters, strike / tail | All groups, strike / tail | Above 3 kHz, recording / fit |
| --- | --- | --- | --- |
| Black | 2.5 / 1.5 dB | 2.5–4.1 / 1.5–3.0 dB | 41 / 36 % |
| Red | 2.1 / 1.5 dB | 2.1–5.1 / 1.3–3.1 dB | 22 / 24 % |
| Brown | 4.1 / 2.1 dB | 2.5–5.8 / 1.3–2.4 dB | 48 / 49 % |
| Blue | 1.9 / 1.4 dB | 1.9–5.5 / 1.3–5.7 dB | 87 / 80 % |

Blue's Return fits worst (5.7 dB in the tail, its decay 7 dB off): its
recording has two strikes about 18 ms apart. Why Red is the default is in
[architecture](../../docs/architecture.md#keyboard).
