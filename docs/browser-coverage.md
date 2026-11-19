# Browser coverage

What the macOS Accessibility system exposes in each browser engine, measured
on 2 November 2026 (macOS 15.7) with the searches Pulse uses: the
`AXUIElementsForSearchPredicate` search VoiceOver's rotor uses, and the
notifications a browser posts while its find bar moves between matches.
Counts are the first 60 results of each search.

Engines: Safari 26 (WebKit), Firefox (Gecko; Zen behaves the same), and
Chrome for Testing (Chromium; an Electron app's built-in browser uses the
same accessibility code and gave identical results on the test page).

## Page structure

| Page | Safari | Firefox | Chromium |
| --- | --- | --- | --- |
| Pulse test page (h1–h3, landmarks, `<article>`, `<mark>`) | 14 headings, 5 regions, 1 article, 3 highlights | 14 headings, 5 regions, 1 article, no highlights | 14 headings, 5 regions + article, no highlights |
| Wikipedia article | 34 headings (h1–h4), 48 regions | 34 headings, 12 regions | 34 headings, 48 regions |
| MDN reference page | 24 headings, 20 regions, 7 articles | 24 headings, 10 regions, 7 articles | 24 headings, 26 regions incl. 7 articles |
| GitHub repository | 27 headings, 8 regions, 1 article | 27 headings, 8 regions, 1 article | 27 headings, 9 regions incl. article |
| Apple Newsroom | 14 headings, 6 regions | 16 headings, 6 regions | 14 headings, 6 regions |
| Hacker News (table layout) | none, 1 form | none | none, 1 region |
| old.reddit.com | 1 heading (a sign-in dialog was open) | 13 headings, 3 regions | 1 heading (sign-in dialog) |
| BBC News | nothing (page did not finish loading) | nothing | nothing |

Heading levels came through in every engine. Hacker News is the expected
Motion-only case: a table layout with no headings, where Pulse falls back to
motion, boundary, and control feedback.

## Waypoint signals

| Signal | Safari | Firefox | Chromium |
| --- | --- | --- | --- |
| Find-in-page match | The page's selection moves to the match (`AXSelectedTextChanged` on the web area) while the find field has focus | Nothing is posted | The find bar announces "Result n of m" (`AXAnnouncementRequested`) |
| Highlighted text (`<mark>`) | `AXHighlightedSearchKey` finds each mark (and its text run) | The search returns nothing | The key is unknown and the search returns every element |

Pulse reads only the two numbers in Chromium's announcement, in memory, to
tell a match from "No results". It recognises Chromium's everything-answer
(the first result is the page itself, or a heading, link, or control) and stops
asking that app for highlights.

## Findings

- **Reliable everywhere:** headings with levels, ARIA landmark regions
  (banner, navigation, main, complementary, content info), and articles
  (Chromium lists them under landmarks). Pulse uses articles as section
  starts alongside headings, which gives feeds and card layouts structure
  in every engine, Firefox and Zen included.
- **The core set:** headings, selection changes in sidebars and tab strips,
  and scroll ends. All three work in every engine on every content page
  tested.
- **WebKit only:** highlights. **WebKit and Chromium:** find-in-page matches.
  Waypoints are opt-in and say so in Settings.
- Firefox builds a page's accessibility tree only once an assistive client
  asks, so the first probe of a freshly loaded page can come back empty; the
  next one finds it.
- Chromium hides a background tab's page from Accessibility entirely: a page
  is only Page-aware while it is on screen.

## Reproducing

`Pulse --probe` reports, for the page under the pointer, whether it is
Page-aware, how many headings it exposes near the viewport, and its scroll
edges. It prints kinds and counts, never text.
