# BLE Scout (iOS)

Walk around a room with your iPhone, along any route. The app tracks where you are
relative to your start point (ARKit), listens to every **named** Bluetooth device
nearby, and finds **clusters** of them. Each cluster shows a distance and direction
from you, a position relative to the start, and a pin in the camera view.

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

1. Stand at your start point, facing into the room, and tap **Start**. The direction
   you face becomes "ahead" on the map.
2. Walk slowly around the room on any route, holding the phone up with the camera
   facing forward. ARKit needs to see things, so avoid pointing it at blank walls or
   the floor. Go past each area at least once, and loop back through the middle.
3. Watch it build:
   - **Map:** heat map of likely device positions, your path, START, and you (blue arrow).
   - **Clusters:** each group of named devices, with "3.4 m · ahead-left" from where
     you stand now, its position relative to the start, and the device names.
   - **Nearby:** named devices loudest right now (walk toward the bar going up).
   - **Camera view:** red pins float where each cluster is.
4. Tap **Stop** when done. The share button exports the raw data (JSON) for later
   analysis.

**Demo** mode (the switch next to Start) runs a fake room with a virtual walker. It's
the only mode in the Simulator, which has no camera or Bluetooth.

## How it works

- **Position** (`Sources/PoseTracker.swift`): ARKit world tracking (camera + motion
  sensors). Accurate to centimetres over a room; drifts slowly over long walks.
- **Bluetooth** (`Sources/BLEScanner.swift`): CoreBluetooth scan with duplicates on.
  Only devices that broadcast a name are kept; unnamed ones are counted, then ignored.
- **Localization** (`Model/Localizer.swift`): readings are grouped into 0.5 m spots
  along your path. A path-loss model (`rssi = P0 − 10·n·log10(d)`) is fitted per
  device on a grid around the area you walked, which gives a position and a confidence
  radius. Devices that stay loud everywhere (your own earbuds or watch) are marked
  "carried by you" and excluded. Devices within 1.5 m of each other form a cluster.
  The analysis re-runs every 2 seconds.

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
