# Cluster: the Pull Up design language

Pull Up borrows from instrument clusters and motorsport timing screens, not
from SaaS dashboards. All tokens live in
`native/ios/Packages/PullUpKit/Sources/PullUpDesign/Tokens.swift`; screens never
hard-code a colour, size or curve.

## Principles

1. **Numbers are the hero.** Speeds and times use compressed, heavy,
   tabular numerals (`ClusterFont.numeral`, `.readout`) so digits don't jitter
   as they change at 1 Hz.
2. **Legends, not labels.** Captions read like stamped instrument legends:
   small, expanded, tracked, uppercase (`Legend`).
3. **Rules, not cards.** Sections are divided by hairlines and tick scales
   (`TickRule`, `SectionHeader`). Plates exist only where something is
   tappable or needs to stand forward.
4. **Chamfers, not pills.** Surfaces use `ChamferedRectangle`: two opposite
   corners cut at 45°, like a machined bezel or a number plate. Photos get a
   4 pt radius at most.
5. **One accent at a time**, chosen by the user (Sodium, Redline, Heritage
   Green, Gulf, Ultraviolet, Titanium) and spent only on what's live,
   selected or actionable. Each vehicle also has an identity colour used for
   its stripe, tile and picker card.
6. **Honest states.** Estimates carry a dashed `EST` mark in amber; server
   verification is green; demo data is labelled at the top of every screen;
   missing values show `––`, never zero.
7. **No decoration for its own sake.** No ambient gradients, glows or glass
   cards. The only gradient is the fill under the speed chart, where it
   encodes area.

## Colour

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| canvas | `#F2F0EB` warm spec-sheet paper | `#0A0B0D` | page |
| plate | `#FBFAF7` | `#121418` | tappable surfaces |
| plateRaised | `#E8E5DE` | `#1B1E23` | selected, forward |
| ink / secondary / tertiary | `#111214` at 100 / 62 / 40% | `#F1EFE9` at 100 / 62 / 38% | text |
| live | `#D93A2B` | `#FF5240` | recording, live meets |
| verified | `#1E8A55` | `#45D08E` | server-checked |
| estimate | `#A86E00` | `#E9B44C` | GPS estimates, demo |
| caution | `#B4471B` | `#FF8A4C` | warnings |

Primary and secondary ink meet WCAG AA (≥ 4.5:1) on canvas and plate in
both modes (secondary is about 5.3:1 in light). Tertiary ink is about 2.7:1 in
light mode and 3.6:1 in dark, so it's used only for non-essential metadata
such as timestamps and hints, never for anything the user must read to act.

## Area by area

* **Drive**: an instrument cluster. Three speedometers (Sweep: 270° analog
  with redline band and top-speed chevron; Digital: compressed numerals over
  a segment bar; Tape: a moving HUD tape). Up to six configurable tiles.
* **Start Drive picker**: the Start button's shape grows upward into the
  picker panel and then into the full-screen dashboard (one
  `matchedGeometryEffect` stage). Vehicle cards are photo-led with an
  identity stripe; selection gets an accent border, a stamped "Selected"
  tag, a spring and a haptic. Accessibility text sizes switch to a list.
* **Garage**: vehicle-first and photo-led. The first vehicle gets a 16:10
  hero, the rest a two-up grid. No photo? A line-drawn silhouette for the
  body style (sedan, coupe, hatchback, wagon, convertible, SUV, truck, van,
  sport bike, naked, cruiser, adventure, scooter) on an identity-tinted plate.
* **Map**: full-bleed MapKit with chamfered meet pins and a floating meet
  strip. Never anyone's live position.
* **Meets**: led by a calendar date stamp (or LIVE), grouped by day.
* **Feed**: media edge to edge; text-only posts are set large with an accent
  rule so they don't pose as missing images.
* **Leaderboards**: big rank numerals, the top three in accent, your row
  raised. Closed-course boards carry a no-street-racing notice.
* **Profile**: owner-chosen layout (Showcase, Garage, Logbook), featured
  vehicle and accent, rendered for every visitor.

## Personalisation

Appearance (system/light/dark), accent, speedometer style, units
(MPH·mi·ft / KM/H·km·m) and dashboard tiles live in `ThemeStore`
(device-local). Profile layout, featured vehicle and profile accent are
account data. Vehicles have identity colours and a manual garage order.

## Accessibility

* Dynamic Type everywhere; the picker switches layout at accessibility sizes.
* Reduce Motion: the stage morph becomes a crossfade, the needle stops
  springing, the live dot stops pulsing, cards stop scaling.
* VoiceOver: readouts read as "Distance, 12.4 mi"; speedometers update
  frequently with "48 MPH, top 71"; hold-to-stop exposes a plain activate
  action; selection is exposed with the selected trait.
* Minimum 44 pt targets.

## Self-review

Findings from reviewing the CI screenshots are recorded in
`docs/PROGRESS.md` under "Design review".
