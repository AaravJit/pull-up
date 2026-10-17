# Device test plan

What to check on a real iPhone (target: iPhone 18 Pro Max) before Pull Up
goes to testers outside the team. Everything here needs a physical device,
a hosted backend, Apple's servers, or a real drive. CI can't cover it.

None of these tests has been run yet. Results go in `PROGRESS.md` under
"physical-device tests passed", with the build number and date. Report each
failure with the **Device test result** issue template.

## Evidence levels

Keep these separate in every report. A higher level never follows from a
lower one.

| Level | Meaning | Where it's recorded |
| --- | --- | --- |
| Automated tests | Unit, package and API tests in GitHub Actions | CI run links in `PROGRESS.md` |
| Simulator tests | UI tests and screenshots on the iOS simulator in CI | Screenshot branch, xcresult |
| Hosted backend tests | API and pgTAP tests run against the staging Supabase project | "Supabase deploy" workflow run |
| Physical-device tests | This plan, on a real iPhone | `PROGRESS.md` and test-result issues |
| TestFlight verified | A build Apple processed, installed from TestFlight | App Store Connect ▸ TestFlight |

## Before you start

* A TestFlight build pointed at **staging** (`TESTFLIGHT_SETUP.md`).
  Settings ▸ About must say "Pull Up server (staging)". Never run these
  tests against production.
* Two Apple IDs signed in to two devices, or one device plus a second
  account you can switch to. Tests marked **2 accounts** need both.
* iOS Settings ▸ Privacy ▸ Location Services on. Battery above 80 % for the
  long-drive tests.
* For drives: a passenger holds the phone or it sits in a mount. Never
  interact with the app while driving. Obey traffic laws. Pull Up is not for
  racing, and no test here needs high speed or hard acceleration.
* Note the build number (Settings ▸ About) in every result.

## 1. Install and first launch

| ID | Steps | Expected |
| --- | --- | --- |
| D1.1 | Install from TestFlight, open | Sign-in screen. No location, notification or tracking prompt yet |
| D1.2 | Sign in with Apple, share email | Onboarding: username, photo, privacy choices. No email/password sign-up anywhere |
| D1.3 | Sign in with Apple, **Hide My Email** | Same; account works with the relay address |
| D1.4 | Delete the app, reinstall, sign in with the same Apple ID | Same account, no second onboarding |
| D1.5 | Settings ▸ Apple ID ▸ Sign-In & Security ▸ Sign in with Apple ▸ Pull Up ▸ Stop using | Next launch or return to foreground signs out |
| D1.6 | Settings ▸ Delete account | Account and data gone; signing in again starts a new account |

## 2. Location permission

| ID | Steps | Expected |
| --- | --- | --- |
| D2.1 | Drive tab ▸ Start Drive ▸ pick a vehicle ▸ confirm | Location prompt appears only now |
| D2.2 | Answer "Don't Allow" | Clear message with an Open Settings button; nothing recorded |
| D2.3 | Allow with Precise Location off | Precise Location notice; recording doesn't start |
| D2.4 | Allow While Using, Precise on | Recording starts; blue location indicator appears when the app is in the background |
| D2.5 | During a drive, turn Precise Location off in Settings | Recording stops; "Precise Location was turned off" notice; drive up to then is kept |

## 3. Recording drives

Record each with a stopwatch and the car's trip meter so the numbers can be
compared. Write down trip-meter distance at start and end.

| ID | Drive | Expected |
| --- | --- | --- |
| D3.1 | 10+ minutes of town driving with lights, phone locked in a mount | Recording continues while locked. Distance within about 3 % of the trip meter (trip meters have their own error). Stops at lights show 0 and "Stopped", not "signal lost" |
| D3.2 | 20+ minutes on a highway at the legal limit | Distance within about 2 %. Top speed close to the highest speed shown on the car's speedometer, which usually reads a few percent high |
| D3.3 | Through a tunnel or multi-storey car park | "GPS signal lost" while inside; summary shows a bridged gap and its length |
| D3.4 | Slow driving in a car park (walking pace) | No wild speeds; distance plausible |
| D3.5 | Parked for 5 minutes with recording on | Distance doesn't grow; moving time doesn't grow |
| D3.6 | Turn on Low Power Mode during a drive | Low Power Mode notice on the dashboard; recording continues |
| D3.7 | Switch vehicle between two drives | Each drive is logged to the vehicle picked for it |
| D3.8 | 0–60 mph result, only if it happened naturally and legally (for example a highway on-ramp) | Labelled an estimate unless the data supports it. Never test this on purpose |
| D3.9 | Discard a drive | Nothing uploaded; it doesn't appear anywhere |

### Interruptions

| ID | Steps | Expected |
| --- | --- | --- |
| D3.10 | Answer a phone call mid-drive, then return | Recording continued |
| D3.11 | Open another app (Maps, music) for 5 minutes mid-drive | Recording continued; blue indicator stayed |
| D3.12 | Force-quit Pull Up mid-drive (swipe up in the app switcher), reopen within 15 minutes | iOS stops recording when the user force-quits; Apple doesn't allow an app to prevent that. On reopening, the drive resumes with a "picked it up again" notice, and the summary shows the closed time as a gap |
| D3.13 | Force-quit mid-drive and reopen after more than 15 minutes | The drive is finished at its last fix and uploaded; a "recovered" notice explains it |
| D3.14 | Restart the phone mid-drive, reopen | Same as D3.12 or D3.13, depending on the time |
| D3.15 | Airplane mode for the whole drive | Drive saved on the phone ("saved offline"); uploads by itself when the connection is back and the app is opened |
| D3.16 | Drive while the phone has no signal at the end, then reconnect | Same as D3.15 |

### Battery

D3.17: a one-hour drive with the phone in a mount, screen locked, starting
above 80 %. Record the battery percentage at start and end, the phone's
temperature (warm, hot) and whether it was charging. Settings ▸ Battery
shows Pull Up's share. These are the only battery numbers Pull Up should
quote; none have been measured yet.

## 4. Social and messages (2 accounts)

| ID | Steps | Expected |
| --- | --- | --- |
| D4.1 | A follows B; B's profile is private | B gets a follow request; A sees nothing private until approved |
| D4.2 | A sends B a message; B has the chat open | Appears within a few seconds without refreshing |
| D4.3 | B turns on airplane mode; A sends two messages; B turns it off and opens the app | Both messages appear and the inbox shows them unread |
| D4.4 | B leaves the app in the background for 10 minutes while A sends | On return to the foreground the chat and unread count are up to date |
| D4.5 | A shares a vehicle, drive and post with B; A then makes them private | B's chat shows them as unavailable |
| D4.6 | Someone A doesn't follow messages A | Lands in Requests; sender can send at most three messages until accepted |
| D4.7 | Block, report, unsend, reactions, read receipts | As in the app's help text; blocked user can't message or see the profile |
| D4.8 | Photo in a message, then check the stored file's metadata | No GPS location in the stored photo |
| D4.9 | No demo profiles anywhere | Only real accounts appear in feed, search, meets and leaderboards |

## 5. Notifications (2 accounts)

Only after the APNs key is set on staging (`SUPABASE_SETUP.md` step 3).

| ID | Steps | Expected |
| --- | --- | --- |
| D5.1 | Settings ▸ Notifications ▸ turn on | iOS prompt appears only now |
| D5.2 | B follows A, likes, comments, messages | A gets each push, with no message text unless previews are turned on |
| D5.3 | Tap a message push | Opens that chat |
| D5.4 | Turn a category off | That kind of push stops |
| D5.5 | Sign out on the phone, sign in to another account | Pushes for the old account stop |

A push is verified only when it shows up on the device. A green server log
doesn't count.

## 6. Pull Up Pro

Only with sandbox testers in App Store Connect, and only after the products
exist there and are approved by the owner. Prices stay proposals until
then.

| ID | Steps | Expected |
| --- | --- | --- |
| D6.1 | Buy monthly with a sandbox account | Pro unlocks after the server confirms with Apple |
| D6.2 | Delete and reinstall, Restore Purchases | Pro returns |
| D6.3 | Sign in to a second Pull Up account on the same phone | Pro does not carry over ("belongs to a different account") |
| D6.4 | Let the sandbox subscription lapse | Pro ends |
| D6.5 | Ask to Buy (sandbox child account) | Pending state, then Pro once approved |

## 7. Parts finder

| ID | Steps | Expected |
| --- | --- | --- |
| D7.1 | Open parts for a garage vehicle | Search links for that vehicle; no prices, ratings or "fits" claims shown as Pull Up's own |
| D7.2 | Open a link | eBay opens in Safari or the eBay app |

## 8. Accessibility and appearance

| ID | Steps | Expected |
| --- | --- | --- |
| D8.1 | Largest Dynamic Type size | Every screen readable; nothing cut off on the live dashboard |
| D8.2 | VoiceOver through Start Drive and the summary | Every control is named; speed and signal are read out |
| D8.3 | Dark and light appearance, Reduce Motion | Readable; no animation with Reduce Motion |
| D8.4 | Dynamic Island and Always-On display during a drive | Nothing obscured |

## Reporting

For every failure, open an issue with the **Device test result** template:
the test ID, build number, iOS version, what happened, what was expected,
and screenshots or a screen recording. Crashes appear in App Store Connect
▸ TestFlight ▸ Crashes; mention the time so they can be matched.
