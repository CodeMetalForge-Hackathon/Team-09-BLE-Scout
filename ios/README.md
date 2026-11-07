# BLE Scout (iOS)

Walk around an area with your iPhone, along any route, and find **hot spots**: places
where several **named** Bluetooth devices (and so, likely, people) are. Then switch to
**Mission** mode for simple live directions to the hot spots with the most devices
first.

## Run it on your iPhone

Needs a Mac with Xcode 16+, an iPhone (iPhone XS or newer) with iOS 17+, and a USB
cable. A free Apple ID is enough.

1. Open the project:
   ```bash
   open ios/BLEScout.xcodeproj
   ```
2. In Xcode, click **BLEScout** (blue icon, top left) → target **BLEScout** →
   **Signing & Capabilities**. Under **Team**, pick your Apple ID (Xcode → Settings →
   Accounts → **+** if it isn't listed). If Xcode says the bundle ID is taken, change
   `com.team9.blescout` to something unique, e.g. `com.yourname.blescout`.
3. Plug in the iPhone, unlock it, and tap **Trust**. Pick it as the run destination in
   Xcode's top bar, then press **▶ Run**.
4. First time only, on the iPhone:
   - Settings → Privacy & Security → **Developer Mode** → on (the phone restarts).
   - Settings → General → VPN & Device Management → your Apple ID → **Trust**.
5. In the app, allow **Camera** and **Bluetooth** when asked.

Apps signed with a free Apple ID expire after 7 days. Press Run in Xcode again to
reinstall.

## Using it

1. **Start:** stand at your start point, face into the area, and tap **Start**. The
   direction you face becomes "ahead" on the map.
2. **Scan:** walk slowly on any route, holding the phone upright with the back camera
   uncovered. The camera is only used for position tracking; nothing is shown or saved.
   Hot spots build up on the map as you walk:
   - **Map:** heat map, your path, START, and hot-spot circles labelled with device counts.
   - **Hot spots:** each one with its device names, a distance and direction from you,
     and its position relative to the start.
   - **Nearby:** named devices loudest right now.
3. **Mission:** tap **Plan mission to hot spots** (or the Mission tab, available any time). The app ranks
   hot spots by device count (ties: nearest first) and guides you to each in turn:
   - a big arrow that turns as you turn, plus "Turn left · 4.2 m" style instructions
   - a live signal meter for the target's devices: **warmer** or **colder**
   - a buzz and "You're there" on arrival
   - **Cleared · next** marks it done and moves on; **Skip** sends it to the end of the list.

   Scanning keeps running during a mission, so positions keep improving and new hot
   spots join the plan. Cleared hot spots only come back if several new devices show
   up there.
4. **Pause** stops scanning; **Resume** continues the same session with positions
   intact (resume near where you paused). The **⋯** menu (while paused) exports the
   raw data (JSON) or starts a **New scan** from scratch.

The app needs a real iPhone: the Simulator has no Bluetooth or motion tracking. The
unit tests use a simulated room (`BLEScoutTests/TestWorld.swift`).

## How it works

- **Position** (`Sources/PoseTracker.swift`): ARKit world tracking (camera + motion
  sensors) with no camera preview. Accurate to centimetres over a room; drifts slowly
  over long walks.
- **Bluetooth** (`Sources/BLEScanner.swift`): CoreBluetooth scan with duplicates on.
  Only devices that broadcast a name are kept; unnamed ones are counted, then ignored.
- **Localization** (`Model/Localizer.swift`): readings are grouped into 0.5 m spots
  along your path. A path-loss model (`rssi = P0 − 10·n·log10(d)`) is fitted per
  device on a grid around the area you walked, which gives a position and a confidence
  radius. Devices that stay loud everywhere (your own earbuds or watch) are marked
  "carried by you" and excluded. Devices within 1.5 m of each other form a hot spot.
  The analysis re-runs every 2 seconds.
- **Mission** (`Model/Mission.swift`): hot spots are re-lettered on every analysis, so
  mission targets are tracked by *which devices they contain*. Order: most devices
  first, then nearest. "Arrived" = within the hot spot's size plus its position error
  (1–3 m).

## Limits

- Bluetooth signal strength is noisy and absorbed by bodies. Expect ±1–2 m. Treat a
  cluster as an area to search, not an exact spot.
- iOS only scans while the app is open and the screen is on (the app keeps the screen
  awake while scanning).
- Many phones (iPhones in particular) don't broadcast a name. Named devices are
  usually earbuds, headphones, watches, fitness bands, speakers, trackers and laptops.
- iOS gives each device a per-phone ID and can change it if the device changes its
  Bluetooth address. Keep scans to a few minutes.

## Develop

```bash
cd ios
xcodegen generate     # regenerate BLEScout.xcodeproj after adding/removing files
xcodebuild test -project BLEScout.xcodeproj -scheme BLEScout -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

## TestFlight

App Store Connect app: **BLE Scout SAR** (`com.evanagizzi.blescout`, team P2Y69G87UF).
Uploads must be built with **Xcode 26+**, so these commands point at
`/Applications/Xcode-26.3.0.app` for this shell only.

1. Bump the build number (`CURRENT_PROJECT_VERSION` in `project.yml`); every upload needs a new one.
2. Archive and upload:
   ```bash
   cd ios && xcodegen generate
   export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
   xcodebuild archive -project BLEScout.xcodeproj -scheme BLEScout -destination 'generic/platform=iOS' \
     -archivePath build/BLEScout.xcarchive -derivedDataPath build/dd26 -allowProvisioningUpdates
   xcodebuild -exportArchive -archivePath build/BLEScout.xcarchive -exportPath build/upload \
     -exportOptionsPlist ExportOptions-testflight.plist -allowProvisioningUpdates
   ```
3. Wait for Apple's "processing complete" email (usually 10–30 min), then add testers
   in App Store Connect → TestFlight.
