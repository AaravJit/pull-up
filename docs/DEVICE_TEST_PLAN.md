# Device test plan

What to check on a real iPhone (target: iPhone 18 Pro Max) before Pull Up
goes to testers outside the team. Everything here needs a physical device,
a hosted backend, Apple's servers, or a real drive. CI can't cover it.

None of these tests has been run yet. Each pass goes in a row of the
"Physical-device tests passed" table in `PROGRESS.md`, with the build
number and date. Report each
failure with the **Device test result** issue template.

Each Expected column describes what the app is built to do, checked against
the code. Where the current app falls short, the row says so and the gap is
listed under [Known gaps](#known-gaps), so a tester can tell a known gap
from a new failure.

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

"Pull Up Settings" means the app's own settings: Feed tab ▸ your profile
(top right) ▸ gear. "iOS Settings" means the iPhone's Settings app.

* A TestFlight build pointed at **staging** (`TESTFLIGHT_SETUP.md`). Pull
  Up Settings ▸ About ▸ Data must say "Pull Up server (staging)"; the Build
  row there is the build number to put in every result. Never run these
  tests against production.
* **2 accounts** means two iPhones, each signed in to its own Apple ID, both
  in use at the same time for the live tests (D4.2, D4.4, D4.7a). Sign in
  with Apple always uses the phone's own Apple ID, so a second account on
  the same phone (D5.5, D6.3) has to be an email account created in the
  staging dashboard, used through "Other ways to sign in".
* The only way to open another person's profile is to tap their name on a
  post in Feed. Before the 2-account tests, each account makes one Public
  post.
* iOS Settings ▸ Privacy & Security ▸ Location Services on. Battery above
  80 % for the long-drive tests.
* The live dashboard keeps the screen awake. To test with the phone locked,
  press the side button.
* For drives: a passenger holds the phone or it sits in a mount. Never
  interact with the app while driving. Obey traffic laws. Pull Up is not for
  racing, and no test here needs high speed or hard acceleration.
* A drive is kept only with at least 30 accepted GPS fixes and 200 m.
  Where a row says "a keepable drive", drive at least 2 minutes and 1 km.

## 1. Install and first launch

| ID | Steps | Expected |
| --- | --- | --- |
| D1.1 | Install from TestFlight, open | Sign-in screen. No location, notification or tracking prompt yet |
| D1.2 | Sign in with Apple, share email | Onboarding: "Pick your handle", "Add a photo", "Who sees what". "Other ways to sign in" only offers email sign-in for accounts set up by Pull Up support; nothing lets you create an account with email |
| D1.3 | Sign in with Apple, **Hide My Email** | Same onboarding; afterwards Pull Up Settings ▸ Account shows "Email: Hidden by Apple" |
| D1.4 | Delete the app, reinstall, open | Either already signed in or the sign-in screen (iOS may keep the saved session). After signing in with the same Apple ID: same @username, no onboarding |
| D1.5 | Signed in with Apple on this phone: iOS Settings ▸ your name ▸ Sign in with Apple ▸ Pull Up ▸ Stop using | Next launch or return to the app signs out, and the sign-in screen says Sign in with Apple was turned off for Pull Up |
| D1.6 | Run last, after every other section. Pull Up Settings ▸ Account ▸ Delete account ▸ type DELETE ▸ Continue with Apple | Sign-in screen says "Your account and everything in it have been deleted." The other account can no longer see this one's posts or profile. Signing in again goes to "Pick your handle" (a new account) |

## 2. Location permission

| ID | Steps | Expected |
| --- | --- | --- |
| D2.1 | Drive tab ▸ Start Drive ▸ pick a vehicle ▸ Start recording | Location prompt appears only now |
| D2.2 | Answer "Don't Allow" | "Location access is off for Pull Up…" with an Open Settings button; nothing recorded |
| D2.3 | Allow with Precise Location off, then Start recording | iOS asks for precise location for this drive. Allowing it starts recording; declining shows "Precise Location is off…" with Open Settings and nothing records. Needs #17; earlier builds skip the iOS prompt |
| D2.4 | Allow While Using, Precise on | Recording starts; the blue location indicator appears when the app is in the background |
| D2.5 | Record a keepable drive, then turn Precise Location off for Pull Up in iOS Settings and return | Recording has stopped and the drive summary opens with the drive saved. The next Start recording behaves as in D2.3. See [Known gaps](#known-gaps): the "Precise Location was turned off" notice isn't shown |

## 3. Recording drives

Record each with a stopwatch and the car's trip meter so the numbers can be
compared. Write down trip-meter distance at start and end.

| ID | Drive | Expected |
| --- | --- | --- |
| D3.1 | 10+ minutes of town driving with lights, phone locked with the side button, in a mount | Recording continues while locked. Distance within about 3 % of the trip meter (trip meters have their own error). At lights speed reads 0; on longer stops "Stopped. Location updates are paused…" may appear. "GPS signal lost" never appears at a light |
| D3.2 | 20+ minutes on a highway at the legal limit | Distance within about 2 %. Top speed close to the highest speed shown on the car's speedometer, which usually reads a few percent high |
| D3.3 | Through a tunnel or multi-storey car park where GPS drops for more than 15 seconds | "GPS signal lost" while inside; summary ▸ Details shows "Bridged signal gaps" with a distance |
| D3.4 | Slow driving in a car park (walking pace) | No wild speeds; distance plausible |
| D3.5 | First add the Moving tile (Pull Up Settings ▸ Drive dashboard ▸ Dashboard tiles). Park for 5 minutes with recording on | Distance and Moving don't grow; the summary's Stopped time includes the 5 minutes |
| D3.6 | Turn on Low Power Mode during a drive | Low Power Mode notice on the dashboard; recording continues |
| D3.7 | Switch vehicle between two drives | Each drive is logged to the vehicle picked for it |
| D3.8 | 0–60 mph result, only if it happened naturally and legally (for example a highway on-ramp) | Always labelled an estimate (EST), even when the summary notes the data was consistent. Never test this on purpose |
| D3.9 | Discard a drive | Nothing uploaded; it doesn't appear anywhere |

### Interruptions

| ID | Steps | Expected |
| --- | --- | --- |
| D3.10 | Answer a phone call mid-drive, then return | Recording continued |
| D3.11 | Open another app (Maps, music) for 5 minutes mid-drive | Recording continued; blue indicator stayed |
| D3.12 | Mid-drive, force-quit Pull Up (swipe up in the app switcher) and keep driving; the passenger reopens it within 15 minutes | iOS stops recording when the user force-quits; Apple doesn't allow an app to prevent that. On reopening, the drive resumes and the dashboard says "Pull Up was closed during this drive and picked it up again…". The summary's Details shows "Bridged signal gaps" with the distance covered while closed |
| D3.13 | Record a keepable drive, force-quit, and reopen more than 15 minutes after the last fix | The Drive tab says "A drive from … was interrupted when the app closed. It was saved up to the last GPS fix." with Dismiss; the drive is in Recent drives, ending at its last fix |
| D3.14 | Restart the phone mid-drive, reopen | Same as D3.12 or D3.13, depending on the time |
| D3.15 | Airplane mode for a whole keepable drive | Summary says "Saved on this device and will upload automatically…"; the Drive tab says "1 drive saved on this device, waiting to upload." With signal back, tap Retry (or close and reopen the app): it uploads and the notice goes. See [Known gaps](#known-gaps) |
| D3.16 | Drive while the phone has no signal at the end, then reconnect | Same as D3.15 |

### Battery

D3.17: a one-hour drive with the phone in a mount, locked with the side
button, starting above 80 %. Record the battery percentage at start and
end, the phone's temperature (warm, hot) and whether it was charging. iOS
Settings ▸ Battery shows Pull Up's share. These are the only battery numbers
Pull Up should quote; none have been measured yet.

## 4. Social and messages (2 accounts)

A and B are the two accounts. Run D4.6 first, while neither follows the
other. Then run D4.1. D4.7e (block) runs last, after section 5, because the
app has no unblock. For the rest A and B follow each other: B turns
Approve new followers off, and each follows the other (if A's request is
still pending, A unfollows and follows again).

| ID | Steps | Expected |
| --- | --- | --- |
| D4.1 | B: Pull Up Settings ▸ Privacy ▸ Approve new followers on, Profile = Friends. A opens B's profile from B's post ▸ Follow | A's button reads "Requested"; B's notifications show that A asked to follow; A sees that only friends can see B's garage and drives. See [Known gaps](#known-gaps): B can't approve yet |
| D4.2 | A sends B a message; B has the chat open | Appears within a few seconds without refreshing |
| D4.3 | B turns on airplane mode; A sends two messages; B turns it off and opens the app | Both messages appear and the inbox shows them unread |
| D4.4 | B leaves the app in the background for 10 minutes while A sends | On return to the foreground the chat and unread count are up to date |
| D4.5 | A sets one vehicle and one drive to Public and Privacy ▸ Drive history to Public, and makes a Public post. B opens A's profile ▸ that vehicle ▸ Message @A ▸ send. A sends B the post (paper-plane button) and the drive (Drive ▸ Recent drives ▸ the drive ▸ ••• ▸ Send summary in a message). A then sets the vehicle and drive to Only me and Privacy ▸ Profile to Only me (posts can't be edited) | B reopens the chat: all three cards show a lock and "No longer available"; A still sees them. Afterwards A sets Privacy ▸ Profile back to Public for the later tests |
| D4.6 | A: Privacy ▸ Who can message you = Everyone. B opens A's profile ▸ Message and sends four messages | A's Messages ▸ Requests shows B. Messages 1 to 3 send; the 4th shows "Not sent. Wait for them to accept your request before sending more." with Retry and Delete. After A taps Accept, B's Retry sends it. |
| D4.7a | A reacts 🔥 to B's message, then taps 🔥 again | The reaction appears for both, then disappears for both |
| D4.7b | A unsends one of A's own messages | A sees "You unsent a message", B sees "Message unsent"; the text is gone |
| D4.7c | B turns off Privacy ▸ Read receipts; both reopen the chat | Neither sees when the other read messages |
| D4.7d | A reports B from the chat | "Thanks for reporting" appears; B isn't told; a row appears in staging's `reports` table |
| D4.7e | Run after section 5. A blocks B | The chat leaves A's inbox; B can't start a chat with A, find A or see A's profile. To undo, delete the row in staging's `blocks` table |
| D4.8 | Send a photo that has a location (in Photos, swipe up shows a map). In the staging dashboard ▸ Storage ▸ dm-media, download that message's .jpg and check it with an EXIF viewer | No GPS fields; longest side 2048 px or less |
| D4.9 | Look through Feed, search, meets and leaderboards | No demo profiles; only real accounts. CI's API tests briefly create "Test …" users on staging and delete them again |

## 5. Notifications (2 accounts)

Only after the APNs key is set on staging (`SUPABASE_SETUP.md` step 3).
Pull Up shows no banner while it is open, so keep A's app in the background
or the phone locked. Repeat follows and likes within 24 hours send no
second push, by design. A message request's push always reads "… wants
to send you a message", with no text whatever the setting.

| ID | Steps | Expected |
| --- | --- | --- |
| D5.1 | Pull Up Settings ▸ Account ▸ Notifications ▸ Push notifications ▸ Allow | iOS prompt appears only now |
| D5.2 | B follows A (unfollow first if needed), likes and comments on A's post, and sends A a message with Show message text off | A gets "… started following you" (unless B already followed A in the last 24 hours), "… liked your post", "… commented on your post" (no comment text) and "… sent you a message" |
| D5.2b | A turns on Show message text; B sends again | Push titled with B's name, showing the message text |
| D5.3 | Tap a message push | It opens that chat |
| D5.4 | Push me about ▸ Messages off; B sends in an accepted chat. Turn it back on; B sends again | No push the first time (the chat still updates); a push the second time |
| D5.5 | Sign out on the phone, sign in to the second account | Pushes for the old account stop |

A push is verified only when it shows up on the device. A green server log
doesn't count.

## 6. Pull Up Pro

Only with sandbox testers in App Store Connect, and only after the products
exist there and are approved by the owner. Prices stay proposals until
then.

| ID | Steps | Expected |
| --- | --- | --- |
| D6.1 | Buy monthly with a sandbox account | "You're Pro…" after the server confirms with Apple |
| D6.2 | Delete and reinstall, sign in with the same Apple ID | Pro is back without tapping anything: Pull Up Settings ▸ Pull Up Pro says Active, and the Pro screen shows the plan with no Restore button |
| D6.3 | Sign in to the second account on the same phone, open the Pro screen, tap Restore purchases | Pro is off; Restore says "This subscription belongs to a different Pull Up account. Sign in to that account to use it." |
| D6.4 | Pro screen ▸ Manage subscription ▸ cancel; wait past the end date; reopen the Pro screen | Plans and Restore show again; Pro looks are locked |
| D6.5 | Ask to Buy (sandbox child account), then approve | "Waiting for approval…", then Pro after the approval (reopen the Pro screen) |

## 7. Parts finder

| ID | Steps | Expected |
| --- | --- | --- |
| D7.1 | Garage ▸ a vehicle ▸ Find parts | Year, make and model filled in from the vehicle; Search eBay stays disabled until a part is entered; the screen says Pull Up shows no listings, prices or sellers and doesn't check fitment |
| D7.2 | Enter a part, Search eBay | eBay opens in the eBay app or Safari |

## 8. Accessibility and appearance

| ID | Steps | Expected |
| --- | --- | --- |
| D8.1 | Largest accessibility text size; go through Start Drive, the live dashboard and the summary | Speed, recording time and every tile value fully visible (numbers may shrink); long vehicle names may end in "…"; the picker becomes a vertical list |
| D8.2 | VoiceOver through Start Drive and the summary | Every control is named; speed and GPS signal are read out; Hold to stop has an action |
| D8.3 | Dark and light appearance; Reduce Motion through Start Drive ▸ dashboard ▸ summary | Readable in both. With Reduce Motion, the stage change is a short crossfade and the REC dot doesn't pulse. See [Known gaps](#known-gaps) for other screens |
| D8.4 | Portrait and landscape during a drive; lock the phone | The dashboard isn't under the Dynamic Island or home indicator. The lock screen shows only iOS's location indicator; Pull Up has no Live Activity |

## Known gaps

Found while checking this plan against the code. Each one makes a row
above behave differently from what a tester might expect. They are not
fixed yet.

* **D2.3:** before #17, Start Drive refuses with "Precise Location is off"
  without iOS ever offering precise location for the drive.
* **D2.5:** the "Precise Location was turned off" notice is never shown.
  The drive summary replaces it, and closing the summary clears it.
* **D3.15:** a saved drive uploads only when the app starts, on sign-in, or
  on Retry, not when the app returns to the foreground.
* **D4.1:** there is no way in the app to approve a follow request.
* **D8.3:** some selection animations ignore Reduce Motion: segmented
  switches, accent swatches, the speedometer picker in Settings, the vehicle
  editor, Pro plans and the map.

## Reporting

For every failure, open an issue with the **Device test result** template:
the test ID, build number, iOS version, what happened, what was expected,
and screenshots or a screen recording. Crashes appear in App Store Connect
▸ TestFlight ▸ Crashes; mention the time so they can be matched.
