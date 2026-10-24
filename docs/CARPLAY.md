# CarPlay

## What Apple allows

CarPlay apps must fit one of Apple's categories, each gated by its own
entitlement that Apple grants on request:

| Category | Entitlement | Fits Pull Up? |
| --- | --- | --- |
| Audio, communication, EV charging, fueling, parking, quick food ordering, navigation | various | No |
| **Driving task** | `com.apple.developer.carplay-driving-task` | **Yes.** Apple describes it as apps that "help people with tasks they need to do while driving", e.g. logging mileage or controlling vehicle accessories |

Constraints for driving-task apps (CarPlay Developer Guide, iOS 16+):

* Templates allowed: list, grid, information, point of interest, alert,
  action sheet. No maps, no custom drawing, so no speedometer.
* The app must be usable without looking at the phone, and must not show
  content that encourages distraction. Apple reviews CarPlay apps against
  this specifically.

## What's built

`native/ios/PullUp/CarPlaySceneDelegate.swift`, declared in `Info.plist`
under `CPTemplateApplicationSceneSessionRoleApplication`.

* Root: an information template with recording status, vehicle, distance,
  elapsed time and GPS state, refreshed every two seconds.
* Start drive: a list of the user's garage vehicles plus Guest. Choosing one
  calls the same `DriveRecorder.start(with:)` the phone uses, so the drive is
  logged to that vehicle.
* Stop and save while recording.
* Current speed is deliberately not shown: the car's own speedometer is the
  authority, and Apple's guidance discourages duplicating it.

It compiles in every CI build and runs in Xcode's CarPlay simulator
(I/O ▸ External Displays ▸ CarPlay) once the entitlement is present in the
signed build.

## Remaining actions (need the Apple Developer account holder)

1. Request the entitlement at
   <https://developer.apple.com/contact/carplay/> choosing **Driving Task**.
   Describe Pull Up as drive logging: start/stop recording and choose the
   vehicle the drive is logged to.
2. When granted, enable "CarPlay Driving Task" on the App ID in
   Certificates, Identifiers & Profiles. Signing is automatic (Xcode
   locally, `-allowProvisioningUpdates` in the TestFlight workflow), so the
   next signed build picks up the capability; there is no profile to
   regenerate by hand.
3. Set `PULLUP_ENTITLEMENTS = PullUp/PullUp-CarPlay.entitlements` in
   `Config/Secrets.xcconfig`. That file already contains the entitlement
   key. This covers builds made on a Mac only: the TestFlight workflow
   writes `Secrets.xcconfig` without `PULLUP_ENTITLEMENTS`, and no CI
   secret or variable sets it, so workflow builds always use
   `PullUp/PullUp.entitlements` (`Base.xcconfig`). A CarPlay TestFlight
   build needs a pull request that adds the setting to the workflow or
   changes `Base.xcconfig` first.
4. Test on a real head unit or a CarPlay-capable aftermarket unit; the
   simulator doesn't exercise the real connection lifecycle.

Without the entitlement the app works normally on the phone; it simply
doesn't appear on the CarPlay home screen.
