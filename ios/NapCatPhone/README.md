# NapCat Phone (iOS receiver)

The iPhone half of F3: it shows the alerts NapCat on the Mac sends. **Part 1
is a UI skeleton with fixture data only.** It has no CloudKit, no network
calls, and no entitlements, so it builds for the **simulator only**, without
code signing.

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

## How the project is put together

- `project.yml` is the [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  spec and the source of truth. `NapCatPhone.xcodeproj` is generated from it
  and committed, so the app builds with Xcode alone. Don't hand-edit the
  `.xcodeproj`. After you change `project.yml`, run `xcodegen generate` in
  this directory and commit both. The local-package entry in the project is
  labelled with the name of the checkout's directory, so regenerate from a
  checkout named `NapCat` to keep that label unchanged.
- `NapCatPhone/` and `NapCatPhoneTests/` are synchronized folders. You can
  add or remove Swift files there without regenerating the project.
- The repository root is a **local Swift package** dependency. The app links
  only its `NapCatWire` product, the shared wire contract (record type, field
  keys, lanes). Nothing else from the Mac package is built for iOS. There is
  no second `Package.swift`.
- The art comes from the repository's own committed files, referenced in
  place rather than copied: `Resources/frames/idle*@2x.png` (the menu-bar
  idle cycle) and `art/groom-source.png` (the grooming cat).
