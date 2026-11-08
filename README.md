# Team 9: BLE Scout

An iPhone app for search and rescue. Walk through an area with your phone and it finds
**hot spots**: places where Bluetooth devices (and so, likely, people) are clustered.
Then **Mission** mode gives live directions to the hot spots with the most devices first,
and **Spin to pinpoint** narrows down the last few metres.

- [`ios/`](ios/): the BLE Scout iPhone app.
- [`groundstation/`](groundstation/): a laptop web app where every phone's scan shows up on
  one live team map. Run `cd groundstation && uv run groundstation`.
- [`pi/`](pi/): a headless Raspberry Pi scanner that uploads Bluetooth readings to the same
  Supabase relay, so it shows up as another device.

The app is in [`ios/`](ios/). See the [iOS README](ios/README.md) for how to run it on
your iPhone, how to use it, how it works, and how to upload to TestFlight.

## Quick start

- **Just use it:** install **BLE Scout SAR** from TestFlight (ask Evana to add you as a tester).
- **Build it yourself:** needs a Mac with Xcode and an iPhone. The Simulator can't scan
  Bluetooth or track movement, so it only shows the intro screen.
  ```bash
  open ios/BLEScout.xcodeproj
  ```
  In Xcode, pick your own iPhone as the run destination, choose your own **Team** under
  BLEScout → Signing & Capabilities, and press ▶ Run.
