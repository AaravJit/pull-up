# Pull Up 1.0 design language

Pull Up 1.0 follows Apple's Human Interface Guidelines first and car culture
second. The app is a social app for people who drive: the feed, messages,
meets and people come first, and Drive is one clear tap away. All tokens live
in `native/ios/Packages/PullUpKit/Sources/PullUpDesign/Tokens.swift`; screens
never hard-code a colour, size or curve. (The token type names, such as
`ClusterColor` and `ChamferedRectangle`, are kept from the earlier "Cluster"
language so the code didn't churn; their values are new.)

## Principles

1. **Familiar before clever.** Native `TabView`, `NavigationStack`, large
   titles, sheets, menus, `.searchable`, swipe actions, disclosure groups and
   system haptics. Nothing a person has to learn twice.
2. **Content is the interface.** Posts, photos, conversations and meets carry
   the screen. Chrome recedes: no borders on surfaces, no stripes, no
   uppercase legends.
3. **One accent, spent sparingly.** Electric Blue marks what you can do next
   (the primary button, the selected segment, your own message bubbles). It
   is never decoration. Other accents remain a personal choice in Settings.
4. **People stay in control.** Nothing is published, shared, sent or
   recorded without an explicit tap. Smart defaults pre-fill (the only
   vehicle, the last one you tagged, your last audience) but never act.
5. **Honest states.** Estimates are marked in amber, server-checked values in
   green, demo data is labelled, missing values show `--`, never zero.
6. **Room to breathe.** Crowding is fixed with space or progressive
   disclosure, never by shrinking text or targets.

## Colour

| Token | Light | Dark (OLED Black) | Use |
| --- | --- | --- | --- |
| canvas | `#FFFFFF` | `#000000` | page, bars, sheets |
| plate | `#F4F4F5` | `#111113` | raised surfaces |
| plateRaised | `#E4E4E7` | `#1C1C1F` | selected, pressed |
| ink | `#09090B` | `#FFFFFF` | primary text |
| inkSecondary | `#52525B` | `#A1A1AA` | secondary text |
| inkTertiary | `#71717A` | `#8A8A93` | timestamps, hints |
| rule | `#E4E4E7` | `#242428` | separators |
| accent (Electric Blue) | `#2563EB` | `#4F8CFF` | actionable, selected |
| accentFill | `#2563EB` | `#2F6FEB` | filled buttons, bubbles |
| live | `#D93A2B` | `#FF453A` | recording, live meets |
| verified | `#15803D` | `#30D158` | server-checked |
| estimate | `#9A6700` | `#FFD60A` | GPS estimates, demo |
| caution | `#C2410C` | `#FF9F0A` | warnings |

Contrast (WCAG 2.x): white on black 21:1; `#A1A1AA` on black 8.2:1;
`#8A8A93` on black 6.1:1; `#4F8CFF` on black 6.5:1; white text on the
`#2F6FEB` dark fill 4.6:1; `#2563EB` on white 5.2:1; `#71717A` on white
4.8:1. Every text colour meets AA (4.5:1) on its canvas.

OLED Black is true `#000000` everywhere, including behind the status bar,
navigation bars, tab bar and sheets (`presentationBackground(canvas)`), so
pixels are off on OLED displays.

### Appearance and migration

Settings > Appearance offers System, Light and OLED Black (the stored raw
value of OLED Black is still `dark`). `ThemeStore` saves a versioned record.
Version 1 records (before 1.0) whose accent was the old default, Sodium, move
to Electric Blue once; any other choice is kept, and choosing Sodium again
after 1.0 sticks. Unknown or corrupt values fall back field by field instead
of resetting everything. A launch override (`-PullUpAppearance`) is never
saved.

## Shape, type and space

* **Shape:** continuous rounded rectangles (`ChamferedRectangle` now draws
  `UnevenRoundedRectangle(style: .continuous)`). Radii: 14 surfaces, 10 small
  controls, 12 photos, 8 chips, 18 message bubbles. Avatars are circles.
* **Type:** San Francisco at standard width, Dynamic Type throughout. Speeds
  keep the compressed numeral (`ClusterFont.numeral`) with monospaced digits
  so they don't jitter. Sentence case everywhere; no tracking.
* **Space:** 20 pt screen gutters; 8 pt between related items; 12-16 pt
  inside groups; 16-20 pt surface insets; 24-32 pt between sections. 44 pt
  minimum targets. Content is capped at a 640 pt readable width on wide
  displays (Pro Max landscape, iPhone Duo inner display).

## Materials

Liquid Glass is used only on the navigation and control layer: the system
tab bar and navigation bars (automatic on iOS 26), and floating controls over
the map (`FloatingControlSurface`: `glassEffect` on iOS 26,
`regularMaterial` before). Content surfaces are opaque. On iOS 26 the tab
bar minimises while scrolling down.

## Navigation

Four tabs: **Feed**, **Messages**, **Explore** (Meets, Map and People in one
segmented control) and **You** (profile, Drive, Garage, Activity, Settings).
Drive opens full screen from You or Explore's steering-wheel button and stays
presented while a drive is recording or finishing. Old deep links and
`-PullUpTab` values (map, meets, garage, drive, dms) land where those screens
live now.

## Area by area

* **Feed:** large title, a "Share a photo, a build update, a drive…" prompt, posts with a
  40 pt avatar, name and time, media first, then actions, then caption.
  Double-tap to like. Text-only posts are set larger.
* **Post composer:** caption (keyboard up), photos, Post. Vehicle tag shows a
  one-tap suggestion; audience is a segmented control; the post type is under
  More options. The draft survives closing the sheet.
* **Messages:** spacious inbox with search, New message in the bar, a simple
  composer with a round send button. From a post's author, a conversation is
  two taps (the author, then Message).
* **Explore:** Meets list, map with glass controls, people search.
* **You:** identity, Start a drive, drive history, leaderboards, a garage
  carousel, Activity and Find parts; Settings in the bar.
* **Drive:** the instrument cluster stays (Sweep, Digital, Tape speedometers,
  configurable tiles). Recording starts only after the vehicle is confirmed.

## Accessibility

Dynamic Type at every size (the drive picker switches to a list at
accessibility sizes), VoiceOver labels and hints on every control, Reduce Motion
respected for springs and the picker transition, 44 pt targets, and colour is
never the only signal (icons and text accompany live, verified and estimate
states).
