# Keyboard boards

Pulse's Mechanical and Ambient typing sounds are resynthesised from measured descriptions
of real keyboards. Nothing recorded ships: for each key group the fitter
finds how loud 21 third-octave noise bands should be at 17 moments in the
first 140 ms, and Pulse plays fresh noise through the same bands, shaped the
same way.

| Board | Measured from (Mechvibes community packs; none of their audio is included) |
| --- | --- |
| Creamy (default) | "Creamy thingy" by yozyrexx |
| Velvet | "WOB Rainy 75 PRO (FR4 + Kailh Cocoa)" by laika_raika300years_otomad |
| Citrus | "Orange deluxe" |
| Alloy | "amazin keychron q3 bluex" by bluecxmbo |
| Crisp | "apex pro tkl bluex" by bluecxmbo |

To re-derive `Sources/PulseCore/BoardRecipeData.swift`, download the packs
yourself, unzip each into a folder (convert an `audio.ogg` with
`afconvert -f WAVE -d LEI16@48000 -c 1 audio.ogg audio.wav`), then:

```sh
cd scripts/boards
python3 fit.py '{"thingy": "/path/creamy", "rainy": "/path/rainy", "orange": "/path/orange", "keychron": "/path/q3", "apex": "/path/apex"}' recipes.json
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
its board's letter keys, and each board's letters as loud as Creamy's. It
needs numpy and takes about three minutes.
