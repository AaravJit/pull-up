# Screen map and state coverage

Written 2026-10-27 against `origin/main` 2addf20, by reading the source. Swift was not compiled or run here, so nothing below was observed on a device or simulator.

**Paths.** Feature paths are relative to `native/ios/Packages/PullUpKit/Sources/PullUpFeatures/`. App-target paths are relative to `native/ios/PullUp/`.

**Cell values:**
- A **file:line** cell is where that state is rendered.
- **MISSING** means the state can happen and nothing handles it.
- **—** means the state can't happen on that screen.

**State columns.** The tables use these short headings:

| Column | State |
|---|---|
| Empty | empty |
| Loading | loading |
| Denied | permission denied |
| Offline / error | offline or error |
| Rejected | rejected upload |
| Deleting | deletion in progress |
| Blocked | blocked user |
| Suspended | suspended account |
| Demo | guest or demo |

Each screen also gets a one-line **Entry** note above its table.

## 1. Navigation

- **App root** (`App/RootView.swift`), by phase:
  - launching: ProgressView
  - setupRequired: `SetupRequiredView` (`Auth/AuthView.swift:218-240`)
  - signedOut: `AuthView`
  - onboarding: `OnboardingView`
  - signedIn: `MainTabView`, with the tabs Drive, Map, Feed, Meets and Garage
- **Launch flags** (`App/LaunchOptions.swift`): `-PullUpDemo`, `-PullUpSignedOut`, `-PullUpOnboarding`, `-PullUpEmptyGarage`, `-PullUpTab`, `-PullUpOpenPush`, `-PullUpAppearance`, `-PullUpResetDefaults`.
- **App target:** `PullUpApp.swift` handles push registration and opening a push. `CarPlaySceneDelegate.swift` isn't reachable in the shipping build, which has no CarPlay entitlement; #29 also removes its scene declaration.

## 2. State matrix

### Shared states

These apply on every screen and are not repeated in the tables below:
- **Demo:** a `DemoStrip`, "Demo data · not real, not saved", runs across every screen in demo mode (`App/RootView.swift:17`, `Shared/Components.swift:7-11`).
- **Suspended:** on main, nothing in the app shows a suspension.

### Auth and onboarding

**AuthView.** Entry: app root, signed out.

| State | Where |
|---|---|
| Error | `Auth/AuthView.swift:60-63` (also the busy state) |
| Demo | Demo sign-in button, `:65-73` |
| Other | Signed-out notice after deletion or revocation, `:34-37` |

**SetupRequiredView.** Entry: app root when there's no backend config.

| State | Where |
|---|---|
| Demo | Offer to use demo mode, `Auth/AuthView.swift:218-240` |

**OnboardingView.** Entry: app root, after first sign-in.

| State | Where |
|---|---|
| Offline / error | Username check `:411`. Privacy settings fall back to defaults when they don't load, `:511-513`. |
| Rejected | Photo upload error near `:448` |

### Drive tab

**DriveHomeView.** Entry: Drive tab.

| State | Where |
|---|---|
| Empty | `Drive/DriveHomeView.swift:219-222` |
| Loading | **MISSING**: the empty text shows while loading (F7) |
| Offline / error | `:217-218` |
| Rejected | `:160-174` (`rejected-uploads`) |
| Other | Pending, recovered and interrupted drives, `:147-178` |

**StartDrivePicker.** Entry: Drive tab, Start.

| State | Where |
|---|---|
| Empty | `Drive/StartDrivePicker.swift:136-141`, `:320-362` |
| Loading | `:132-135` |
| Denied | `:281-294` (Open Settings) |
| Offline / error | **MISSING**: the garage error reads as "garage empty" (F1) |

**LiveDashboardView.** Entry: picker, Start.

| State | Where |
|---|---|
| Denied | Interruption when accuracy is reduced or permission is revoked mid-drive (`Drive/DriveRecorder.swift:301-306`) |
| Offline / error | GPS lost or waiting, `Drive/LiveDashboardView.swift:162-167` |
| Demo | Replay notice, `:151-152` |

**DriveSummaryView.** Entry: end of a drive (`Drive/DriveTabView.swift:62-67`), and history.

| State | Where |
|---|---|
| Offline / error | Saved offline `Drive/DriveSummaryView.swift:144`; save error `:297`; delete error `:43` |
| Rejected | `:146` (also too short `:148`, not saved `:150`) |
| Deleting | Confirmation dialog `:89-91` |
| Demo | "Demo · not server-checked", `:124-125` |

**DriveHistoryDetail.** Entry: DriveHomeView `:50`, VehicleDetailView `:227`.

| State | Where |
|---|---|
| Loading | `Drive/DriveSummaryView.swift:403` |
| Offline / error | `:400-401` (retry) |

**LeaderboardView.** Entry: DriveHomeView `:52`.

| State | Where |
|---|---|
| Empty | `Leaderboards/LeaderboardView.swift:110-111` (opt-in prompt) |
| Loading | `:108-109` |
| Offline / error | `:106-107`. The privacy load uses `try?`, `:49` |

**NotificationsView.** Entry: the bell, `Drive/DriveHomeView.swift:286`.

| State | Where |
|---|---|
| Empty | `Profile/NotificationsView.swift:33-34` |
| Loading | **MISSING**: blank until loaded (F8) |
| Offline / error | `:31-32` |

### Map tab

**MapScreen.** Entry: Map tab.

| State | Where |
|---|---|
| Empty | **MISSING**: no "no meets" or "no routes" message (F9) |
| Loading | Blank canvas until loaded, `Map/MapScreen.swift:43-46` |
| Offline / error | Meets error `:50`. Routes fail silently, `:169-172` |
| Demo | "Demo" legend, `:126` |

### Feed tab

**FeedView.** Entry: Feed tab.

| State | Where |
|---|---|
| Empty | `Feed/FeedView.swift:36-45` |
| Loading | `:36-45` |
| Offline / error | `:36-48` |
| Blocked | Hides the author after a block (report/block menu `:265-290`) |

**PostComposerView.** Entry: FeedView `:80`. Owned by post-uploads (#33).

| State | Where |
|---|---|
| Rejected | Error `Feed/PostComposerView.swift:64`; video too big `:119`, can't prepare `:124` |

**CommentsView.** Entry: FeedView `:81`.

| State | Where |
|---|---|
| Empty | "No comments yet" |
| Loading | **MISSING** (F3) |
| Offline / error | **MISSING**: `try?` at `Feed/FeedView.swift:450`; offline shows "No comments yet" (F3) |
| Blocked | `onBlocked` hides the author |

**ProfileView.** Entry: FeedView `:70` (route).

| State | Where |
|---|---|
| Empty | Not-viewable notice, `Profile/ProfileView.swift:117-120` |
| Loading | `:49` |
| Offline / error | `:46-47`. Vehicles and drives fail silently, `:331`, `:333` (F4) |
| Blocked | `:42-43` |

**ProfileEditorView.** Entry: ProfileView sheet.

| State | Where |
|---|---|
| Offline / error | `Profile/ProfileView.swift:545` |

**ReportPersonView.** Entry: Profile, Feed, Meet.

| State | Where |
|---|---|
| Offline / error | `Profile/ProfileView.swift:422` (offset 55 inside the view) |
| Other | Sent: `EmptyState`, `:394` |

**SharedDriveView.** Entry: ProfileView `:267`.

| State | Where |
|---|---|
| Empty | "Route not shared", `Profile/SharedDriveView.swift:233-244` |
| Loading | `:233-244` |
| Offline / error | `:233-244` |

**VehicleGlanceView.** Entry: ProfileView sheet.

| State | Where |
|---|---|
| Offline / error | `Messages/ShareToMessageView.swift:157` |

### Settings (from FeedView `:71`)

**SettingsView.** Entry: FeedView `:71`.

| State | Where |
|---|---|
| Loading | Privacy section, `Settings/SettingsView.swift:149-184` |
| Offline / error | `:149-184` (retry) |
| Demo | "Data" row reads Demo, `:273-300` |

**PrivacyZonesView.** Entry: SettingsView `:207`.

| State | Where |
|---|---|
| Empty | List |
| Loading | **MISSING** (F2) |
| Offline / error | **MISSING**: `try?` at `Settings/SettingsView.swift:481` (F2) |

**PrivacyZoneEditor.** Entry: PrivacyZonesView.

| State | Where |
|---|---|
| Denied | Falls back to the Sacramento region, `Settings/SettingsView.swift:499` |
| Offline / error | `:536` |

**NotificationPreferencesView.** Entry: SettingsView `:187`.

| State | Where |
|---|---|
| Loading | `Settings/NotificationSettings.swift:183-191` |
| Denied | Push denied, Settings button, `:137-150` |
| Offline / error | `:183-191` |

**DeleteAccountView.** Entry: SettingsView `:38`. Owned by account-deletion (#31).

| State | Where |
|---|---|
| Offline / error | `Settings/DeleteAccountView.swift:37` |
| Deleting | Busy, `:38` |
| Other | Manual Apple revocation steps, `:53-65` |

**ProView.** Entry: `.proSheet` (Settings `:39`, DriveProSection `:50`).

| State | Where |
|---|---|
| Loading | `Pro/ProView.swift:161` |
| Offline / error | `:163-177` |
| Demo | "Demo: prices are placeholders", `:26` |

### Messages (from FeedView `:72`)

**InboxView.** Entry: FeedView `:72`, and opening a push.

| State | Where |
|---|---|
| Empty | `Messages/InboxView.swift:39-56` |
| Loading | `:39-56` |
| Offline / error | `:39-56` |
| Other | Requests notice, `:33-38` |

**ThreadView.** Entry: Inbox `:94-95`, Profile, ShareToMessage `:168`.

| State | Where |
|---|---|
| Loading | `Messages/ThreadView.swift:35` |
| Offline / error | `:137-138` |
| Rejected | Pending row with Delete, `:521` |
| Deleting | Delete-conversation dialog, `:70-73` |
| Blocked | Block action `:66` |
| Suspended | Only as an error string, "Messaging is paused on your account." (`PullUpData/SupabaseBackend.swift:703-718`), shown at `:137` |
| Demo | "Demo conversation…", `:172-173` |

**ReportView.** Entry: ThreadView `:62`.

| State | Where |
|---|---|
| Offline / error | `Messages/SharedCard.swift:153` |
| Other | Sent: `:125-127` |

**ShareToMessageView.** Entry: FeedView `:87` (share).

| State | Where |
|---|---|
| Empty | `Messages/ShareToMessageView.swift:54` |
| Offline / error | Sending `:52`. Recent and search fail silently, `:87`, `:93` (F10) |

### Meets tab

**MeetsView.** Entry: Meets tab.

| State | Where |
|---|---|
| Empty | `Meets/MeetsView.swift:49-50` |
| Loading | `:47-48` |
| Offline / error | `:45-46` |

**MeetDetailView.** Entry: MeetsView `:56`, MapScreen `:72`.

| State | Where |
|---|---|
| Empty | Attendees empty, `Meets/MeetsView.swift:372` |
| Offline / error | `:241`. Attendees fail silently, `:407` (F10) |
| Blocked | Host blocked, then dismiss, `:412-422` |
| Other | At capacity, `:329` |

**MeetComposerView.** Entry: MeetsView `:71`.

| State | Where |
|---|---|
| Denied | The map shows no user dot and still works, `Meets/MeetComposerView.swift:83` |
| Offline / error | `:62` |

### Garage tab

**GarageView.** Entry: Garage tab.

| State | Where |
|---|---|
| Empty | `Garage/GarageView.swift:88-89` |
| Loading | `:86-87` |
| Offline / error | `:84-85` |

**VehicleDetailView.** Entry: GarageView `:62`.

| State | Where |
|---|---|
| Empty | Mods `Garage/VehicleDetailView.swift:175`, drives `:220`. Removed vehicle `:28` |
| Offline / error | Photo error `:81`. Mods, photos and drives fail silently, `:244-246` (F4) |
| Rejected | Photo upload error, `:264` |

**VehicleEditorView.** Entry: GarageView `:64`, VehicleDetailView `:38`.

| State | Where |
|---|---|
| Offline / error | `Garage/VehicleEditorView.swift:93`. Default visibility uses `try?`, `:112` |
| Deleting | Delete-vehicle dialog, `:115-118` |

**ModEditorView.** Entry: VehicleDetailView `:40`.

| State | Where |
|---|---|
| Offline / error | `Garage/VehicleDetailView.swift:316` |

**ArrangeGarageView.** Entry: GarageView `:65`. No loading or error state applies.

**PartsFinderView.** Entry: GarageView `:63`, VehicleDetailView `:61`.

| State | Where |
|---|---|
| Empty | No vehicle picker when the garage is empty, `Parts/PartsFinderView.swift:55` |
| Offline / error | eBay didn't open, `:181` |

## 3. Findings: missing or misleading states

Highest severity first.

| # | Sev | Screen | Finding | Owner |
|---|---|---|---|---|
| F0 | Medium | All | **No suspended-account state on main.** A suspended person sees raw errors (only Messages maps 42501 to "Messaging is paused"). | moderation (#32 adds a banner and `my_moderation_status`) |
| F1 | Medium | StartDrivePicker | **"Your garage is empty" offline.** `GarageStore.reload()` sets `isLoaded = true` even on error, so a person offline is invited to add a vehicle they already have. Fix: in the picker, show `app.garage.loadError` with retry before the empty state, as `GarageView.swift:84` does. | this track (proposal only) |
| F2 | Medium (privacy) | PrivacyZonesView | **Silent load failure.** `zones = (try? await …) ?? []` at `SettingsView.swift:481`. Offline, the list shows no protected places, so a person may think their home zone is gone and add duplicates, or assume routes aren't protected. Fix: keep an `error` state and show `ErrorLine` with retry, as the editor does at `:536`. | this track (proposal only) |
| F3 | Low | CommentsView | `try?` at `FeedView.swift:450`. Offline reads as "No comments yet", and there's no spinner. | — |
| F4 | Low | ProfileView, VehicleDetailView | Vehicles, drives, mods and photos load with `try?` (`ProfileView.swift:331,333`; `VehicleDetailView.swift:244-246`). Errors look like empty sections. | — |
| F5 | Low (privacy) | Sign-out | `AppModel.apply(nil)` (`App/AppModel.swift:169-179`) keeps the account's unsent drive drafts (raw GPS) and `recorder.lastResult`. Drafts are filtered by owner, so other accounts don't see them. privacy.md now says so. | — (account-deletion #31 clears them on delete) |
| F6 | Low | App root | A failed `account()` lookup lets the person in (`AppModel.swift:161-163`). That's fine for offline use; the server still enforces RLS. | — |
| F7 | Low | DriveHomeView | No loading state for recent drives; the empty text shows first. | — |
| F8 | Low | NotificationsView | No spinner. | — |
| F9 | Low | MapScreen | No empty message for either layer; route failures are silent (`:169-172`). | — |
| F10 | Low | ShareToMessage, MeetDetail attendees | Silent `try?` on secondary lists. | — |

Additional moderation (#32) items:
- No unblock and no blocked-accounts list.
- #32 adds app-wide hiding after a block.

## 4. Demo and replay labels (for the screenshot plan)

Demo mode is `-PullUpDemo`. It uses `DemoBackend` and a temporary `LocalDriveStore`; drives are replayed by `ReplayLocationProvider` (`App/AppModel.swift:93-117`).

| Label | Where |
|---|---|
| Global strip, "Demo data · not real, not saved" | Every screen (`App/RootView.swift:17`). **It shows in any screenshot taken in demo mode.** |
| "Demo" legend | Map header, `Map/MapScreen.swift:126` |
| "Demo: replaying a recorded track instead of live GPS." | LiveDashboardView, `Drive/LiveDashboardView.swift:151-152` |
| "Demo · not server-checked" | DriveSummaryView verdict, `Drive/DriveSummaryView.swift:124-125` |
| "Demo conversation. Replies here are simulated on this device." | ThreadView header, `Messages/ThreadView.swift:172-173` |
| "Demo: prices are placeholders and no payment is taken." | ProView, `Pro/ProView.swift:26` (Pro isn't offered, so don't screenshot it) |
| "Data: Demo" row | SettingsView About, `Settings/SettingsView.swift:273-300` |
| Demo sign-in button, demo offer | AuthView `:65-73`, SetupRequiredView `:218-240` |

**Screens with no demo label of their own** (they carry only the global strip): Feed, Meets, Garage, Profile, Inbox, Leaderboard, DriveHome. `DriveHistoryDetail` uses `TelemetryEngine.replay` (`Drive/DriveSummaryView.swift:415`) to redraw a saved drive. That's real data, not demo, and carries no label.

Store screenshots must be truthful. If they're taken in demo mode, either keep the strip or the captions must not imply real users; this is the policy track's call. Screenshots of the live dashboard in demo show the replay notice.
