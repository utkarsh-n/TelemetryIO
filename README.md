# Telemetry I/O

A native, iPhone-only SwiftUI instrument for iOS 27, built from Spectra's **glass over phosphor** language and Gyre's tactile dials and direct manipulation.

## Play

- **Field:** orbit, scope and channel-history views. Drag the field to generate touch X/Y telemetry. Select a channel, change gain or history window, or inspect its trace.
- **Channels:** a searchable census of public sensor, radio, device and app-output channels. Every channel includes units, public API provenance, permissions and limitations. Drag a trace to inspect recent history.
- **Patch:** connect an input to field energy, orbit speed, hue, local tone pitch/level or haptic drive. Change depth, inversion and time smoothing. Motion, Sound and Touch presets are starting points. Physical outputs stay opt-in.
- **Session:** recent source events, nearby BLE advertiser details, and deliberate CSV export.

Launch starts passive public device/network state. Enable protected inputs from the source menu, an inspector, or a patch connection. Demo is explicit; generated inputs are marked **DEMO**. Nothing silently substitutes a fake for missing hardware.

The pause control stops sensors, camera, microphone, scanning and physical outputs. The last values and traces remain visible. Backgrounding also stops capture. Session tokens for UWB expire on stop and need to be exchanged again.

## Inputs

Motion includes raw acceleration/rotation/magnetic field, fused gravity/user acceleration/attitude and derived movement energy. Other channels include pressure/relative altitude, pedometer, foreground location/heading/accuracy, microphone digital levels/FFT, camera RGB/luminance/ISO/exposure, BLE advertisements/RSSI, path/interface state/quality, cellular access technology, aggregate interface receive/transmit rates, battery/charging/thermal/brightness/proximity, audio route/volume/sample rate and touch.

Nearby Interaction supports deliberate, real peer ranging and direction when a supported participating phone supplies them. Open the UWB inspector on both phones, prepare sessions, share each token to the other phone, then connect on both. It cannot range arbitrary phones or AirTags.

NFC reads NDEF record count/type in a user-started foreground session, without storing payloads. See signing below.

## Accuracy and privacy

Public iOS APIs cannot expose a universal view of every app's sensor/radio use, RF I/Q or baseband traffic, cellular dBm, general Wi-Fi scanning/RSSI, raw GNSS satellite telemetry, private battery current/temperature or biometric internals. Aggregate interface traffic cannot identify the responsible app and may include other apps' traffic. Rings are amplitude mappings, not antenna locations or bearings.

Derived signals name their source. Microphone dBFS is not calibrated SPL; camera luminance is not ambient lux; thermal state is a category, not °C; location is a fused estimate. Full API/source map: [Documentation/Capabilities.md](Documentation/Capabilities.md).

Capture stays in memory, bounded to **600 samples per channel** (about 30 seconds at 20 Hz, longer for slow/event sources). Switching modes clears visible traces so live and demo aren't mixed. CSV retains the provenance of each captured sample. Location coordinates are included if those channels were enabled. CSV files are created only by the export action and are shared only through the native share sheet. Patch settings persist in app-local UserDefaults.

## Build

Open `TelemetryIO.xcodeproj` in Xcode 27, or run:

```sh
Tools/build.sh sim
Tools/build.sh test
Tools/build.sh ui
Tools/build.sh device
swift test --package-path Core --scratch-path /tmp/TelemetryIOCoreTests
```

The build script mirrors sources to a local temporary directory before invoking Xcode, following Gyre's workaround for coordinated reads in the Documents checkout. Simulator builds/tests default to the dedicated **TelemetryIO QA** iPhone 15 Pro Max. Override `TELEMETRY_SIMULATOR_ID` to select another simulator and `TELEMETRY_BUILD_DIR` to use another scratch location. Run `xcodegen generate` after source/project changes.

`TelemetryIOTests` runs the app-hosted input, routing, lifecycle, export, DSP, and actual audio-render tests, including pending audio activation cancellation, rapid re-enable, concurrent mic/tone ownership, and driver cleanup. Microphone capture requires microphone access in that simulator. The opt-in location test uses `TELEMETRY_TEST_LOCATION=1` after injecting `37.3349,-122.0090` and granting simulator location access; it validates Core Location delivery, not physical GNSS. `TelemetryIOUI` contains nine real app UI scenarios, a separate Settings accessibility smoke test, and screenshot attachments. `Tools/build.sh ui` runs that scheme serially on the selected simulator. Simulator-only hardware reports UNAVAILABLE rather than inventing input or haptic actuation.

The normal signed build works without special network entitlements. NFC additionally needs a development profile that includes **NFC Tag Reading** and the supplied `TelemetryIO/NFC.entitlements` (`NDEF` format). Enable that capability and build with `CODE_SIGN_ENTITLEMENTS=TelemetryIO/NFC.entitlements`. Missing NFC capability reports a session error. No private entitlement inspection is used.

Launch arguments: `-demo` starts explicitly labeled synthetic inputs; `-channels` or `-patch` opens the corresponding tab for QA.

## Validation

Core tests cover channel metadata consistency, normalization, bounded history, stale transitions, provenance mode handling, depth/inversion, elapsed-time smoothing, patch lifecycle/source loss, continuous orbital phase, and interface counter wrap/reset/gaps. Simulator automation and physical scenario evidence are tracked in `Documentation/QA.md`; a compile or install alone does not verify sensor accuracy, audible output, tactile feel, physical NFC or two-phone UWB.


## Public snapshot

See [PUBLICATION.md](PUBLICATION.md) for publication exclusions and setup requirements.
