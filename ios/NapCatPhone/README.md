# NapCat Phone (iOS receiver)

The iPhone half of F3: it shows the alerts NapCat on the Mac sends. A
**device build** reads them from the owner's private iCloud database (the
one the Mac writes) and gets a push for each new one. **Simulator builds,
previews and tests use fixture data only.** They never build a CloudKit
container, so they still build and run without code signing. See
[Live alerts](#live-alerts-device-builds).

## Requirements

- **Xcode 16 or later** (full Xcode.app, not just the Command Line Tools).
  The project uses Xcode 16 synchronized folders and needs an iOS 18+ SDK.
  It is verified with Xcode 27.2 and the iOS 27.2 simulator runtime.
- An installed iOS simulator runtime. The app's deployment target is iOS 18.0.
- You don't need XcodeGen to build. You only need it to regenerate the
  project after you edit `project.yml` (see below).

The Mac app does not depend on any of this. `make` and `make test` at the
repository root never build `ios/`.

## Build (simulator, unsigned)

Run from the repository root:

```sh
xcodebuild \
  -project ios/NapCatPhone/NapCatPhone.xcodeproj \
  -scheme NapCatPhone \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/NapCatPhone-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Change the destination `name=` to any installed iPhone simulator. To list
them, run `xcrun simctl list devices available`. The app bundle lands at
`/tmp/NapCatPhone-DerivedData/Build/Products/Debug-iphonesimulator/NapCatPhone.app`.

Unit tests (Swift Testing, hosted in the app) use the same invocation with
`test` in place of `build`.

## Install and launch on a simulator

```sh
xcrun simctl boot 'iPhone 17'        # once; "already booted" is fine
xcrun simctl install booted /tmp/NapCatPhone-DerivedData/Build/Products/Debug-iphonesimulator/NapCatPhone.app
xcrun simctl launch booted com.muratalkan.napcat.phone
```

## Style and fixture states

The style is **Pixel Nap**: cream grounds (warm charcoal in dark mode), ink
borders with a hard shadow, square corners, monospaced labels and an 8 pt
spacing rhythm. Its empty state shows the smooth grooming cat as a large,
faint watermark behind the message. It comes in three palettes, which
change colors only: **Night Groom** (the default), **Deep Cream** (deeper
cream grounds and a warmer night) and **Neutral** (a gray watermark in
light mode).

Launch arguments choose what the screen shows. They are read from the
`UserDefaults` argument domain, and unknown values fall back to the default.
A recognised `-NapCatFixture` value also forces fixtures on a device build;
`-NapCatConnection` applies to fixtures only (a live pill is probed).

| Argument | Values | Default |
|---|---|---|
| `-NapCatFixture` | `populated`, `empty` | `populated` |
| `-NapCatConnection` | `connected`, `iCloudUnavailable`, `notificationsOff`, `pushNotSetUp` | `connected` |
| `-palette` | `nightGroom`, `deepCream`, `neutral` | the stored choice |
| `-NapCatScreen` | `receiver`, `settings` | `receiver` |

The chosen palette is kept in the app's defaults under the key `palette`.
Passing `-palette` picks one for that launch only and leaves the stored
choice alone. `-NapCatScreen settings` opens the launch on Settings (for
screenshots). Neither forces fixtures on a device build.

A live launch's first pill, **Checking…**, is not a launch value (no
probe answers it). The SwiftUI preview "Checking" shows it.

```sh
xcrun simctl launch booted com.muratalkan.napcat.phone \
  -NapCatFixture empty -NapCatConnection notificationsOff
xcrun simctl ui booted appearance dark      # or light; relaunch to compare
xcrun simctl io booted screenshot shot.png  # wait ~3 s after launch first
```

The 3 s wait covers the launch and lets the row entrance (under 0.6 s)
settle.

Every style decision lives in `NapCatPhone/Theme/`. `Theme.swift` defines
the token set: colors, type, surfaces and spacing, the icon variant, the
empty-state art treatment and the entrance curve. `PixelNapTheme.swift`
holds the one style, Pixel Nap, and takes its colors from a palette.
`Palette.swift` holds the palettes: each is a set of color tokens (an sRGB
value and alpha for light and for dark mode) and nothing else. The views
read only the `theme` environment value, so a color change is an edit to
`Palette.swift`.

The fixtures are synthetic. Each alert carries exactly the wire record's
three fields (body, lane, firedAt), and each body is written word for word as
the Mac generates it. No topic, server, host or user name appears anywhere.

## Settings

The gear in the main screen's toolbar opens Settings
(`NapCatPhone/Settings/`) as a sheet; **Done** or a swipe down closes it.
It is one standard grouped form in the current palette:

- **Appearance**: the palette. It changes colors only, applies at once (the
  form included), and is kept across launches.
- **Notifications**: whether this iPhone may buzz (**On**, **Off** or
  **Checking…**), and a button to this app's page in the system's
  notification settings. It shares its words and that button with the main
  screen's permission row.
- **About**: the version and build, read from the app's Info.plist, and a
  link to the [project site](https://muratalkan06.github.io/NapCat/).

Settings works only on what it is handed and on the Info.plist. It makes no
iCloud or network calls, and a test scans its source to keep it that way.

## Live alerts (device builds)

Where the list comes from is one seam, `AlertSource`. `FixtureAlertSource`
serves fixtures. `CloudKitAlertSource` (`NapCatPhone/Live/`, the app's only
CloudKit file) serves the real thing. A launch goes live only when it is a
device build and no `-NapCatFixture` argument was passed. Simulator builds
are always fixture builds: an unentitled CloudKit container traps instead of
returning an error, and the simulator only reaches CloudKit's Development
environment anyway.

A live launch:

1. Asks once for notification permission (alerts and sound) and registers
   for remote notifications. Until the first account check answers, the
   pill reads **Checking…**.
2. Checks the iCloud account. No usable account shows **iCloud unavailable**.
3. Makes sure the one push subscription exists. It fetches the subscription
   by its fixed ID (`AlertWire.subscriptionID`) and creates it only when the
   server has none. A refusal is logged and retried on the next foreground.
   Until the subscription is confirmed, the pill reads **Connected — no
   push**: alerts still load whenever the app opens, but none is pushed.
   (**Notifications off** takes precedence, because the owner can fix that in
   Settings.)
4. Fetches the newest `Alert` records (newest first, up to 50). It does this
   again on every return to the foreground and on every push. A push also
   names the record it announces, and that record is fetched directly by ID,
   because the query's index can lag a record created moments ago. A push
   that names no usable record relies on the query alone. Rows are keyed
   by the record name the Mac wrote, so a record seen twice is one row.
   Records with a missing or unknown field are skipped.

The notification itself is rendered by iOS from the subscription: title
"NapCat", the record's body as the text, default sound. The app schedules no
notification of its own. A push that arrives while the app is open updates
the list without a banner. The app declares no background modes, so it is
never woken in the background. Whatever arrived while it was closed is
fetched when it opens.

Logs (codes and counts only):
`log stream --predicate 'subsystem == "com.muratalkan.napcat.phone"'`.

### Entitlements and the CloudKit environment

`project.yml` generates `NapCatPhone.entitlements` with CloudKit (container
`iCloud.com.muratalkan.napcat`), `aps-environment` (development; an App Store
or TestFlight export rewrites it) and
`com.apple.developer.icloud-container-environment`. That last one is set from
the build setting `NAPCAT_CLOUDKIT_ENVIRONMENT`, which defaults to
**Production**, where the Mac writes. Override it for one build like this:

```sh
xcodebuild … NAPCAT_CLOUDKIT_ENVIRONMENT=Development
```

Apple documents that a subscription is created in Development first and then
promoted with a schema deploy. Creating one directly in Production fails, and
the F3 spike's Mac run hit exactly that refusal (CloudKit error 12). If the
device run shows `push subscription not created (code 12)`, do this:

1. Run one Development build so the subscription is created there.
2. Deploy the schema to Production in the CloudKit Console.
3. Run the Production build again.

Which environment a dev-signed build actually reaches is recorded in #94
once the device run measures it.

## How the project is put together

- `project.yml` is the [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  spec and the source of truth. `NapCatPhone.xcodeproj` is generated from it
  and committed, so the app builds with Xcode alone. Don't hand-edit the
  `.xcodeproj`. After you change `project.yml`, run `xcodegen generate` in
  this directory and commit both. The local-package entry in the project is
  labelled with the name of the checkout's directory, so regenerate from a
  checkout named `NapCat` to keep that label unchanged.
- `NapCatPhone.entitlements` is written by `xcodegen generate` from
  `project.yml` too. Commit it with the project, and never edit it by hand.
  The app's Info.plist is generated from build settings (the
  `INFOPLIST_KEY_…` entries in `project.yml`). There is no Info.plist in the
  source tree. It declares `ITSAppUsesNonExemptEncryption` as NO, because
  the app's only encryption is the system's HTTPS and CloudKit transport.
- `NapCatPhone/PrivacyInfo.xcprivacy` is the app's privacy manifest: no
  tracking, no collected data, and the one required-reason API the app
  uses, `UserDefaults` (reason CA92.1: it reads its own launch arguments
  and keeps the chosen palette).
  A test scans the app's code and NapCatWire for every required-reason API
  category and fails if the manifest declares more or fewer than it finds.
- Versions: the app has its own version line, independent of the Mac app.
  `MARKETING_VERSION` starts at 0.1.0, and `CURRENT_PROJECT_VERSION` (the
  build number) goes up by 1 for every TestFlight upload. TestFlight builds
  get no `vX.Y.Z` tag.
- `NapCatPhone/` and `NapCatPhoneTests/` are synchronized folders. You can
  add or remove Swift files there without regenerating the project.
- The repository root is a **local Swift package** dependency. The app links
  only its `NapCatWire` product, the shared wire contract (record type, field
  keys, lanes). Nothing else from the Mac package is built for iOS. There is
  no second `Package.swift`.
- The art comes from the repository's own committed file, referenced in
  place rather than copied: `art/groom-source.png` (the grooming cat).
- The app icon, `NapCatPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png`,
  is committed and regenerated byte for byte by `make iosicon`.
