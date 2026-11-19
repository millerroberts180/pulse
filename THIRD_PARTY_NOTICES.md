# Third-party notices

## Tactile

Pulse's element role table, control-size and fragment/wrapper heuristics,
control identity rules, destructive-word list, and event sampling gates are
adapted from Tactile (https://github.com/Mason363/Tactile).

MIT License

Copyright (c) 2026 Mason Chen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Mechvibes

The Mechanical and Ambient typing sounds' keyboard boards are recipes
measured from four sound packs in Mechvibes
(https://github.com/hainguyents13/mechvibes), at commit
16afce45bd7cf12be399e2d1a8d20f221067f534:

| Board | Measured from |
| --- | --- |
| Black | `soundpacks/keyboard/cherrymx-black-abs` (CherryMX Black, ABS keycaps) |
| Red | `soundpacks/keyboard/cherrymx-red-abs` (CherryMX Red, ABS keycaps) |
| Brown | `soundpacks/keyboard/cherrymx-brown-abs` (CherryMX Brown, ABS keycaps) |
| Blue | `soundpacks/keyboard/cherrymx-blue-abs` (CherryMX Blue, ABS keycaps) |

What is measured: for each kind of key, how loud 21 third-octave noise bands
are over the first 140 ms of a keystroke, how narrow its low bands may be,
and how loud it is against the board's letter keys. No audio from the packs
is included in Pulse or in this repository. Pulse plays fresh noise shaped by
the measured levels.

The repository's owner recorded these packs and has said that its MIT
licence covers the recordings too, including commercial use and processed
excerpts, on the condition of keeping the copyright and licence notice:
https://github.com/hainguyents13/mechvibes/issues/120#issuecomment-6568249356 (2 November 2026).

How the measurements are made: [scripts/boards](scripts/boards/README.md).

MIT License

Copyright (c) 2026 Hải Nguyễn

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
