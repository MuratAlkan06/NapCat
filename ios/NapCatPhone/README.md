# NapCat Phone (iOS receiver)

The iPhone half of F3: it shows the alerts NapCat on the Mac sends. A
**device build** reads them from the owner's private iCloud database (the
one the Mac writes) and gets a push for each new one. For remote
approvals it also pairs with the Mac and, while its own switch is on,
lists the permission prompts it finds in that database, read only: it
cannot answer them yet. **Simulator builds, previews and tests use fixture
data only.** They never build a CloudKit container, so they still build and
run without code signing. See [Live alerts](#live-alerts-device-builds) and
[Live prompts](#live-prompts-device-builds).

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
| `-NapCatRequest` | `pending`, `expired`, `withdrawn`, `unpaired`, `changed` | none |
| `-NapCatPairing` | `scan`, `camera`, `cameraOff`, `code`, `stray`, `taken`, `noCamera` | none |

The chosen palette is kept in the app's defaults under the key `palette`.
Passing `-palette` picks one for that launch only and leaves the stored
choice alone. `-NapCatScreen settings` opens the launch on Settings (for
screenshots). Neither forces fixtures on a device build.

`-NapCatRequest` opens the launch on a fixture permission prompt (remote
approvals, slice S3) in that state, answered in memory and signed by a
software fixture key: nothing leaves the phone. Allow and Deny each ask for
Face ID or Touch ID (slice S-PAIR-B: every answer is signed); with none
enrolled neither is offered. `unpaired` shows a pending prompt on a phone
with no paired key (no answer is offered), and `changed` one whose
biometrics changed since it paired. It leaves the alert list's source alone.

`-NapCatPairing` opens the launch on the pairing screen (slice S-PAIR-B)
over a fixture ceremony: a software key in memory, a fixture writer and a
fixture camera (the simulator has no camera, so the viewfinder is drawn
empty). `scan`, `camera` and `cameraOff` wait for a scan with the camera
allowed, not yet asked, or off; `code` scans the fixture code at launch
(the simulator's Face ID asks, then the screen shows this iPhone's code to
compare); `stray` scans a code that is not NapCat's; `taken` scans the
fixture code when a response for it is saved already; `noCamera` opens
on the ending a camera that couldn't scan leaves (the scanner wouldn't
start, or stopped mid-scan): its line and **Scan Again**. Outside the
fixtures, the pairing screen opens from Settings › Pairing › **Pair with
Mac** (slice S-PAIR-C1.6), and its code comes from the camera alone.

A live launch's first pill, **Checking…**, is not a launch value (no
probe answers it). The SwiftUI preview "Checking" shows it. Nor is a failed
fetch; the previews "Couldn't check, …" show it. With
`-NapCatConnection iCloudUnavailable` a fixture list reads as not checked,
exactly as a live one would: the populated set shows the stale line and the
empty set says iCloud is unavailable.

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
- **Pairing** (slice S-PAIR-C1.6): **Pair with Mac** opens the pairing
  screen over Settings, a new pairing each time, only when you tap it. On
  your Mac, choose **Pair iPhone…** (a Mac never paired) or **Pair a New
  iPhone…** (a Mac already paired) in NapCat's Settings › Claude, then scan
  the code it shows and confirm with Face ID or Touch ID (the footer names
  the one this iPhone has). A launch with a request fixture has no row.
- **Remote approvals** (shown with Pairing): **Prompts on This iPhone**,
  this iPhone's own switch, off by default and kept across launches. It can
  be set only on a paired iPhone; on an unpaired one it shows off and its
  footer says to pair first. It tells the Mac nothing: off pauses this
  iPhone only (see [Live prompts](#live-prompts-device-builds)).
- **About**: the version and build, read from the app's Info.plist, and a
  link to the [project site](https://muratalkan06.github.io/NapCat/).

Settings works only on what it is handed and on the Info.plist. It makes no
iCloud or network calls of its own, and a test scans its source to keep it
that way; the pairing it opens writes its one record to iCloud through the
live pairing it is handed, and the switch it sets is handed on to the
inbox, which does the reading.

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
   pill reads **Checking…**, and until the first fetch answers an empty
   list reads **Checking for alerts…**. "No alerts. Your Mac hasn't needed
   you." appears only once a fetch has come back empty.
2. Checks the iCloud account. No usable account shows **iCloud unavailable**
   (and, with nothing listed, "iCloud unavailable. Alerts can't arrive
   without it."; with rows listed, they stay under one note: "Stale —
   iCloud unavailable, so new alerts can't arrive").
3. Makes sure the one push subscription exists. It fetches the subscription
   by its fixed ID (`AlertWire.subscriptionID`) and creates it only when the
   server has none. A refusal is logged and retried on the next foreground
   or pull to refresh. Until the subscription is confirmed, the pill reads
   **Connected — no push**: alerts still load whenever the app opens, but
   none is pushed.
   (**Notifications off** takes precedence, because the owner can fix that in
   Settings.)
4. Fetches the newest `Alert` records (newest first, up to 50). It does this
   again on every return to the foreground, on every push, and when you
   pull the list down. A pull runs the whole pass (the account check, the
   subscription retry while it is unconfirmed, the fetch), and its spinner
   stays up until a pass begun after the pull has finished. A push also
   names the record it announces, and that record is fetched directly by ID,
   because the query's index can lag a record created moments ago. A push
   that names no usable record relies on the query alone. Rows are keyed
   by the record name the Mac wrote, so a record seen twice is one row.
   Records with a missing or unknown field are skipped. A fetch that fails
   keeps the list and says so: with rows listed, one line under the header
   reads "Stale — couldn't check for new alerts just now"; with none,
   the empty state reads "Couldn't check for alerts just now. Pull down to
   check again." The next fetch that answers clears it. Wherever the screen
   says it couldn't get alerts (that hero, the iCloud one, or a stale
   note), VoiceOver and Switch Control also offer a **Check again** action
   that runs the same pass as a pull. The list keeps at
   most 50 rows; a full list ends with "Capped — the list keeps the latest
   50 alerts" (it says the rule; it can't know whether older ones exist).

The notification itself is rendered by iOS from the subscription: title
"NapCat", the record's body as the text, default sound. The app schedules no
notification of its own. A push that arrives while the app is open still
shows its banner and plays its sound, and its row comes into the list on
the entrance curve (under Reduce Motion it is simply there). The app
declares no background modes, so it is
never woken in the background. Whatever arrived while it was closed is
fetched when it opens.

Logs (codes and counts only) are the iPhone's own, not the Mac's: open
Console.app on the Mac, select the iPhone under Devices, and search for
subsystem `com.muratalkan.napcat.phone`. A plain `log stream` on the Mac
never shows them. For a simulator run, read the simulator's log instead:
`xcrun simctl spawn booted log stream --predicate 'subsystem == "com.muratalkan.napcat.phone"'`.

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

## Live prompts (device builds)

Remote approvals are not armed: the Mac forwards no prompt yet, and
this iPhone cannot answer one. A device build does this only while
**Prompts on This iPhone** is on and the iPhone is paired:

1. Makes sure the prompt push subscription exists: looked up by its fixed
   ID (`ApprovalWire.promptSubscriptionID`) before the launch's first read,
   created only when missing, and tried again at the next read if that
   failed.
2. Reads one snapshot of the approvals zone, asking for the prompt record's
   six fields only, at launch, on every return to the foreground, as
   **Prompts on This iPhone** is turned on, on a pull to refresh, as
   Settings or the launch's pairing sheet closes, and on a prompt push that
   reaches the open app or is tapped; never on a timer. A prompt record is
   read strictly, and any other record is dropped after its type is
   checked. A failed read changes nothing.
3. Lists the prompts under **Waiting** (tool, project and age). A row, or a
   tapped prompt push, opens the prompt as a preview: the tool, the project
   and the input, with no answer on offer.

The prompt push says "A permission prompt is waiting." under
the title "NapCat", with the default sound: nothing of the prompt but its
record's ID, which opens it, and no action. Switching **Prompts on This
iPhone** off empties the list; it deletes the subscription only if the
switch took effect earlier in the same launch, and if that fails it tries
again on each return to the foreground, pull to refresh, close of Settings
or the launch's pairing sheet, or prompt push while the app stays open. A
deletion still owed when the app quits is not retried by a later launch, so
that subscription stays and its pushes still come. Nothing tells the Mac.
What the live database runs for this path is listed in
[design/remote-approvals.md](../../design/remote-approvals.md), "The
phone's prompt path".

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
  The pairing and the signed answers use cryptography to authenticate
  only: a P-256 signature from the Secure Enclave, a SHA-256 digest and an
  HMAC-SHA256 tag. None of them encrypts anything, so the answer stays NO.
- `NapCatPhone/PrivacyInfo.xcprivacy` is the app's privacy manifest: no
  tracking, no collected data, and the one required-reason API the app
  uses, `UserDefaults` (reason CA92.1: it reads its own launch arguments
  and keeps the chosen palette and the Remote approvals switch).
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
