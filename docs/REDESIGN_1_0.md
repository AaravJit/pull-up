# Pull Up 1.0 redesign: before and after, validation, limitations

Branch `claude/project-thread-kfuo7m`, stacked on #40 (`claude/store-media`).
The legacy Expo app at the repository root is untouched; every change is in
`native/ios/`, `.github/workflows/store-media.yml` and `docs/`.

The design language itself is in [DESIGN.md](DESIGN.md).

## Before and after

| Area | Before (main) | After (1.0) |
| --- | --- | --- |
| Identity | "Cluster": instrument-cluster legends, uppercase tracked captions, chamfered corners, hairline tick rules, warm paper light mode | HIG-led: sentence case, SF at standard width, continuous rounded corners, borderless surfaces |
| Colour | Sodium orange default accent; canvas `#0A0B0D` / `#F2F0EB` | Electric Blue default; OLED canvas `#000000`, light `#FFFFFF`; surfaces `#111113`, separators `#242428` |
| Appearance | System, Light, Dark | System, Light, OLED Black, with live previews in Settings; black reaches bars and sheets |
| Tabs | Drive, Garage, Map, Meets, Feed (Messages behind a feed button) | Feed, Messages, Explore (Meets, Map, People), You |
| Drive | A tab, the app's first screen | Full-screen flow from You or Explore; stays up while recording |
| Garage | A tab | In You (carousel plus See all) |
| Posting | Type picker, audience, vehicle and caption all up front | Caption with keyboard up, photos, Post; one-tap vehicle suggestion; audience segmented; post type under More options; draft kept |
| Messages | Pushed from the feed's toolbar | Its own tab; inbox search; New message; round send button |
| Profile / settings | Settings reached from Garage | You hub: identity, counts, Drive, Garage, Activity, Find parts, Settings |
| Glass | None | Liquid Glass on tab and navigation bars (system) and map controls (iOS 26), material fallback on iOS 18-25 |

Simulator screenshots of both versions are on the `ci/screenshots` branch
(main's latest run and this branch's run) and the store media set is listed
in the media manifest.

## What didn't change

Every feature is still reachable: drives, the live dashboard and its three
speedometers, summaries and the 0-60 estimate (kept as Aarav chose), the
garage, vehicle details and editing, leaderboards, meets and RSVP, the map,
the feed, comments, likes, reports and blocks, messages and requests,
notifications and their preferences, parts finder, protected places,
privacy settings, account deletion, and Pull Up Pro (still hidden unless
offered). Server-side values (accent raw values, audience, post kinds) are
unchanged, so no backend or migration change is needed.

## Validation

Filled in from CI as runs complete; see the PR description for the final
numbers.

## Limitations

* **No real-device verification.** Everything here was checked on GitHub's
  macOS simulators. Nothing was run on a physical iPhone.
* **iPhone Duo inner display.** The simulator boots folded and there is no
  command-line control to open it (see the probe output in the media run's
  `duo/probe/unfold-investigation.txt`). Inner-display screenshots and
  previews need the manual steps in the media verification report.
* **Liquid Glass** is only visible on iOS 26 and later. The runners for
  ordinary CI use Xcode 26.6 (iOS 26.5 SDK); store media uses Xcode 27.1.
* **Demo content has no photos.** The demo backend's posts are text and its
  vehicles show silhouettes, so the screenshots show no car photos. Adding
  real photos needs images Pull Up has the rights to (Aarav's own).
* **Accent choices other than Electric Blue** keep their earlier values; only
  the default changed.
