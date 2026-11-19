# Pulse — Logo Guidelines

![Pulse logo](pulse-lockup-horizontal.svg)

## 1. The logo

**Soft Pulse**: a flat line that rises into one soft, round pulse and settles,
the shape of the haptic pulse Pulse plays. Round, not a heartbeat spike;
one line, not rings.

Built on a 256-unit grid (unit 8): baseline at y 170 from x 28 to 228, the
pulse peaking at y 82 over x 128, stroke 24 with round caps and joins. Flat
tangents at the base and the top keep it a bump, never a spike. It sits 2 %
above centre, the optical centre. The masters are stroke-based: scale the
drawing and the stroke together.

| File | Use |
| --- | --- |
| `pulse-app-icon.svg` | The macOS app icon: an 824-unit body (radius 186) on the 1024 grid, Pulse Violet, white symbol at 62 % |
| `pulse-symbol-violet.svg` / `-black.svg` / `-white.svg` | The symbol on its own, in brand colour, one-colour ink, and reversed |
| `pulse-symbol-small.svg` | 32 px and below: shorter tails, a taller pulse, stroke 32 |
| `pulse-symbol-square.svg` | Centred on a square canvas, for avatars |
| `pulse-wordmark.svg` | "pulse", lowercase, built from the symbol's stroke |
| `pulse-lockup-horizontal.svg` / `-reversed.svg` | Symbol and wordmark, for light and dark backgrounds |
| `png/` | Transparent PNGs of the above, and the menu-bar template images at 4× |

In the app, `Sources/Pulse/UI/PulseLogo.swift` draws the same geometry (app
icon, menu-bar mark); `scripts/make-icon.sh` rebuilds `Resources/AppIcon.icns`.

## 2. Clear space

Keep clear space equal to the pulse's height (88 units on the symbol's grid,
about 40 % of its width) on every side of the symbol and the lockup.

## 3. Minimum size

| Version | Screen |
| --- | --- |
| Horizontal lockup | 96 px wide |
| Symbol | 24 px wide; below 32 px use `pulse-symbol-small.svg` |
| App icon | 16 px (the icon set includes the small-size cut) |
| Menu bar | 18 pt template image; muted, the pulse goes flat |

## 4. Colour

One colour and white. No gradients, no shadows on the mark itself (the app
icon's soft body shadow is the macOS icon convention).

| Name | HEX | RGB | Use |
| --- | --- | --- | --- |
| Pulse Violet | `#5B4FE6` | 91 79 230 | App icon body, the symbol in colour |
| Ink | `#16161D` | 22 22 29 | One-colour symbol, the wordmark on light backgrounds |
| White | `#FFFFFF` | 255 255 255 | The symbol on Pulse Violet, the wordmark on dark backgrounds |

White on Pulse Violet has a contrast ratio of 5.7:1 (passes WCAG AA); Ink on
white, 18:1. For print, CMYK is about 60 66 0 10 (a plain conversion, not a print
profile; proof it), and the nearest Pantones are 2725 C and 2726 C: check a
physical swatch.

## 5. Typography

The wordmark is drawn, not typeset: monoline lowercase from the symbol's
24-unit stroke with round terminals, x-height 104, so no font licence is
involved. Alongside it in the interface, use the system font (SF Pro).

## 6. Don'ts

- Don't add rings, a dot, or a second pulse; one soft pulse is the idea.
- Don't sharpen the pulse into a heartbeat spike or a zig-zag.
- Don't recolour beyond Pulse Violet, Ink, and White, or add gradients.
- Don't stretch it, change the stroke weight on its own, or outline it.
- Don't set the wordmark in another typeface.
- Don't place the violet symbol on busy images or mid-tone backgrounds; use
  the white or Ink version.

## 7. Notes

Chosen from several concepts, then audited and tested at small sizes. No
trademark search has been done: run one before relying on the mark publicly.
