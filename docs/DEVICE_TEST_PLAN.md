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
  the same phone (E, used in D5.2, D5.5 and section 6) has to be an email
  account created in the staging dashboard, used through "Other ways to
  sign in". The first time E signs in, finish its onboarding (handle, then
  Profile: Public under "Who sees what").
* After section 1, A adds two vehicles (Garage ▸ Add vehicle ▸ year, make
  and model ▸ Save), with a real year, make and model. D3.7, D4.5, D7.1 and
  D9.2 need them.
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
| D1.3 | On the second phone, whose Apple ID hasn't used Pull Up yet (Apple only offers the choice the first time): Sign in with Apple, **Hide My Email**. This becomes account B | Same onboarding; afterwards Pull Up Settings ▸ Account shows "Email: Hidden by Apple" |
| D1.4 | Delete the app, reinstall, open | Either already signed in or the sign-in screen (iOS may keep the saved session). After signing in with the same Apple ID: same @username, no onboarding |
| D1.5 | Signed in with Apple on this phone: iOS Settings ▸ your name ▸ Sign in with Apple ▸ Pull Up ▸ Stop using | Next launch or return to the app signs out, and the sign-in screen says Sign in with Apple was turned off for Pull Up. Sign in with Apple again afterwards: same @username, no onboarding |
| D1.6 | Run last, after every other section. Pull Up Settings ▸ Account ▸ Delete account ▸ type DELETE ▸ Continue with Apple | Sign-in screen says "Your account and everything in it have been deleted." The other account can no longer see this one's posts or profile. Signing in again goes to "Pick your handle" (a new account) |

## 2. Location permission

| ID | Steps | Expected |
| --- | --- | --- |
| D2.1 | Drive tab ▸ Start Drive ▸ pick a vehicle ▸ Start recording | Location prompt appears only now |
| D2.2 | Answer "Don't Allow" | "Location access is off for Pull Up…" with an Open Settings button; nothing recorded |
| D2.3 | Allow with Precise Location off, then Start recording | iOS asks for precise location for this drive. Allowing it starts recording; declining shows "Precise Location is off…" with Open Settings and nothing records. Every build from `main` has this (#17, merged); builds from before #17 skip the iOS prompt |
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
| D3.5 | First add the Moving tile (Pull Up Settings ▸ Drive dashboard ▸ Dashboard tiles). Park for 5 minutes with recording on, then drive on at least 200 m before stopping the recording | Distance and Moving don't grow; the summary's Stopped time includes the 5 minutes |
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

### Shared route privacy

| ID | Steps | Expected |
| --- | --- | --- |
| D3.18 | Pull Up Settings ▸ Protected places ▸ Add a protected place, centred where the drive will start ▸ Save. Pull Up Settings ▸ Privacy: Allow route sharing on, trim at 200 m. Record a drive of at least 3 km that starts inside the protected place and ends at least 1 km from it (the server trims the protected place, its margin and up to 450 m at each end, and refuses to share what's left if it's under 200 m). On its summary set "Who can see this drive" to Friends or Public ▸ Save changes ▸ Share trimmed route | The map shows a dashed route (with "Dashed: the trimmed route others can see…") that starts outside the protected place and its 150 m margin, and stops at least 200 m short of where the drive ended. Note the drive's date and time in the result. See [Known gaps](#known-gaps): the other account can't view it in the app |

## 4. Social and messages (2 accounts)

A and B are the two accounts. Run D4.6 first, while neither follows the
other. Then run D4.1. D4.7e (block) runs last, after section 5, because the
app has no unblock. For the rest A and B follow each other: B turns
Approve new followers off, and each follows the other (if A's request is
still pending, A unfollows and follows again).

| ID | Steps | Expected |
| --- | --- | --- |
| D4.1 | B: Pull Up Settings ▸ Privacy ▸ Approve new followers on. A opens B's profile from B's post ▸ Follow. Then B sets Privacy ▸ Profile to Friends, and A goes back to Feed (without refreshing) and opens B's profile again from the same post | A's button reads "Requested"; B's notifications show that A asked to follow; on reopening, A sees that only friends can see B's garage and drives. Afterwards B sets Profile back to Public. See [Known gaps](#known-gaps): B can't approve yet |
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
| D4.9 | Look through Feed, meets and leaderboards, and the people search when sending a post (paper-plane button ▸ search). The app has no other search | No demo profiles; only real accounts. The staging API suite (run by hand from the `Supabase deploy` workflow; CI's API tests use the local stack) briefly creates test users on staging and deletes them again |
| D4.10 | A: Feed ▸ New post ▸ Add ▸ pick a clip under 100 MB filmed on the phone ▸ Public ▸ Post. B turns Wi-Fi off (cellular only), opens Feed and plays A's video | The post appears with the video. On cellular it starts playing and plays to the end with the standard controls; note in the result how long it took to start |

## 5. Notifications (2 accounts)

Only after staging has the APNs secrets and `PUSH_WEBHOOK_SECRET` (`SUPABASE_SETUP.md` step 3) and the push trigger's three Vault secrets and `pg_net` are set up (step 5; migration `20261028000100` sends both the `x-pullup-webhook-secret` and an `Authorization: Bearer` header). `send-push` itself is already deployed on staging. Until then, notifications still show in the app's bell but nothing is pushed.
Pull Up shows no banner while it is open, so keep A's app in the background
or the phone locked. Repeat follows and likes within 24 hours send no
second push, by design. A message request's push always reads "… wants
to send you a message", with no text whatever the setting.

| ID | Steps | Expected |
| --- | --- | --- |
| D5.1 | Pull Up Settings ▸ Account ▸ Notifications ▸ Push notifications ▸ Allow | iOS prompt appears only now |
| D5.2 | On B's phone sign in as E (B's follow is too recent to push again) and follow A, then sign back in with Apple as B. B likes and comments on A's post and sends A a message with Show message text off | A gets "… started following you" from E, "… liked your post", "… commented on your post" (no comment text) and "… sent you a message" |
| D5.2b | A turns on Show message text; B sends again | Push titled with B's name, showing the message text |
| D5.3 | Tap a message push | It opens that chat |
| D5.4 | Push me about ▸ Messages off; B sends in an accepted chat. Turn it back on; B sends again | No push the first time (the chat still updates); a push the second time |
| D5.5 | On A's phone sign out and sign in to E, a staging email account, which makes one Public post. B likes A's post and sends A a message; then B follows E. Afterwards sign out and sign back in with Apple as A, for the tests that follow | Nothing arrives for A. E gets "… started following you" |

A push is verified only when it shows up on the device. A green server log
doesn't count.

## 6. Pull Up Pro

Only with sandbox testers in App Store Connect, and only after the products
exist there and are approved by the owner. Prices stay proposals until
then. Staging also needs the `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`,
`APPSTORE_BUNDLE_ID` and `APPSTORE_PRIVATE_KEY` secrets, `verify-subscription`
and `app-store-notifications` deployed, and App Store Connect's Sandbox
Server Notifications URL pointing at staging's `app-store-notifications`
(`RELEASE_CHECKLIST.md` 4a). Without them Pro never turns on and
renewals aren't recorded, whatever the app does. Buy as E, the staging email account from D5.5, because it can sign in
on either phone (D6.4). Both phones use the same sandbox tester (iOS
Settings ▸ App Store ▸ Sandbox Account).

| ID | Steps | Expected |
| --- | --- | --- |
| D6.1 | Signed in as E, buy monthly | "You're Pro…" after the server confirms with Apple; the Pro screen shows Purchase: Test (sandbox) |
| D6.2 | Leave it renewing. The sandbox renews a monthly plan every few minutes; after three renewals reopen the Pro screen | Still Pro, Renews shown. The developer checks on staging that E's row in `entitlements` has a later `expires_at` than right after D6.1 |
| D6.3 | Delete and reinstall, sign in as E | Pro is back without tapping anything: Pull Up Settings ▸ Pull Up Pro says Active, and the Pro screen shows the plan with no Restore button |
| D6.4 | On the second phone, sign out of B and sign in as E | Pro is Active there too, without tapping anything. Afterwards sign out and sign back in with Apple as B |
| D6.5 | On the first phone, sign in with Apple as A, open the Pro screen, tap Restore purchases | Pro is off; Restore says "This subscription belongs to a different Pull Up account. Sign in to that account to use it." |
| D6.6 | Sign out and sign back in as E. Pro screen ▸ Manage subscription ▸ cancel; wait past the end date; reopen the Pro screen | Plans and Restore show again; Pro looks are locked. Afterwards sign back in with Apple as A |
| D6.7 | Ask to Buy (sandbox child account): tap Subscribe | "Waiting for approval…" and Pro stays off. The sandbox can't approve or decline the request; approval is only testable with StoreKit Testing in Xcode, so stop here |

A sandbox refund isn't in this list; see [Known gaps](#known-gaps).

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
| D8.3 | Dark and light appearance; Reduce Motion through Start Drive ▸ dashboard ▸ summary | Readable in both. With Reduce Motion, the stage change is a short crossfade, the picker's vehicle cards don't grow or shrink when you select one, the speedometer needle jumps to each new speed instead of springing, and the REC dot doesn't pulse. See [Known gaps](#known-gaps) for other screens |
| D8.4 | Portrait and landscape during a drive; lock the phone | The dashboard isn't under the Dynamic Island or home indicator. The lock screen shows only iOS's location indicator; Pull Up has no Live Activity |

## 9. CarPlay

Only once Apple has granted the CarPlay Driving Task entitlement and the
build includes it (`CARPLAY.md`). Needs a real CarPlay head unit; the
simulator doesn't exercise the connection.

| ID | Steps | Expected |
| --- | --- | --- |
| D9.1 | Signed out of Pull Up, connect the phone to the head unit and open Pull Up there | "Signed out: Open Pull Up on your iPhone to sign in." and no buttons |
| D9.2 | Sign in on the phone, then on the head unit tap Start drive | "Choose vehicle" lists the garage vehicles and "Guest vehicle" |
| D9.3 | Pick a vehicle and drive a keepable drive (the passenger checks the phone) | The phone records; the head unit shows the drive's status and "Stop and save" |
| D9.4 | Mid-drive, unplug the phone, then plug it back in | Recording carries on on the phone; on reconnecting the head unit shows the same drive with "Stop and save" |
| D9.5 | Tap Stop and save on the head unit | The drive is in Recent drives on the phone, logged to the vehicle picked in D9.3 |

## Known gaps

Found while checking this plan against the code. Each one makes a row
above behave differently from what a tester might expect. They are not
fixed yet.

* **D2.5:** the "Precise Location was turned off" notice is never shown.
  The drive summary replaces it, and closing the summary clears it.
* **D3.15:** a saved drive uploads only when the app starts, on sign-in, or
  on Retry, not when the app returns to the foreground.
* **D3.18:** the app has no screen that shows another person's shared
  route, so the second-account check in `RELEASE_CHECKLIST.md` can't be
  done in the app. Who can read a shared route is covered by the
  two-account API tests; the developer checks the stored copy of the D3.18
  drive on staging.
* **D4.1:** there is no way in the app to approve a follow request.
* **Pro refund:** Pull Up has no in-app refund request, which is how Apple's
  sandbox issues a refund, so a refund can't be run on a device yet. The
  server's handling of Apple's refund notification has unit tests only.
* **D8.3:** some selection animations ignore Reduce Motion: segmented
  switches, accent swatches, the speedometer picker in Settings, the vehicle
  editor, Pro plans and the map.

## Reporting

For every failure, open an issue with the **Device test result** template:
the test ID, build number, iOS version, what happened, what was expected,
and screenshots or a screen recording. Crashes appear in App Store Connect
▸ TestFlight ▸ Crashes; mention the time so they can be matched.
