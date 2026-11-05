# Pal Again on Apple TV

A record of what was tried, measured and decided on 5 November 2026, so nobody has to find it out again. No Apple TV app exists yet. This folder holds a working proof only, and nothing here is part of the iPhone and iPad app or its builds.

## Where it stands

**An Apple TV works as a Muse gadget.** On an Apple TV (4th generation), the Muse app found the gadget over Bluetooth and paired with it directly. The gadget registered with Muse, and a caption sent by Muse appeared on the television.

| Step | Result | Evidence |
|---|---|---|
| Advertising over Bluetooth | Works | `advertising started, error: none` on the device |
| The Muse app finding it | Works | The Muse app listed the gadget by name and tried to connect, by the owner's report |
| Encrypted pairing | Works | `Encrypted pairing confirmed` in the device log |
| Credentials over Bluetooth | Works | `Device credentials stored in Keychain; pairing complete` |
| Noise session and registration | Works | `Registered with Muse` |
| A command from Muse | Works | `display.set_caption: ok`, and the owner saw the text on the television |
| Speech through the television | Not confirmed | The command exists. Nobody has reported hearing it |

The owner proposed this route: the Apple TV advertises as a gadget, and the phone finds it in Muse.

## The one trick it depends on

The tvOS SDK refuses `CBPeripheralManager`, `CBMutableService` and `CBMutableCharacteristic` at compile time (`'init(delegate:queue:)' is unavailable in tvOS`). The classes are nevertheless present on the device and work when reached through the Objective-C runtime: `NSClassFromString`, `perform(_:with:with:)` and `method(for:)`.

All of this lives in [`Proof/Probe/TVMusePeripheral.swift`](Proof/Probe/TVMusePeripheral.swift). It has the same interface as the iOS `MusePeripheral`, so `PairingCoordinator` works unchanged.

**A compile error says what the SDK allows, not what the system can do.** Reading it as a hard limit sent this work towards a needless helper device for a while. See [Routes that were tried](#routes-that-were-tried).

App Review has not seen this. It may treat it as use of a non-public API, and the outcome is unknown until an app is submitted.

## What the Wi-Fi step needs

During pairing, the Muse app asks the gadget for Wi-Fi networks. tvOS gives apps no way to read the network name, and the Apple TV is already online, so the proof offers a placeholder called `Apple TV network`. Choosing it completes pairing, and no password was requested. A real app must explain this step, because people will be asked to choose a network that is not theirs.

## What tvOS offers

Checked by compiling against the tvOS 27.2 SDK with a deployment target of tvOS 17, unless noted. "Compiles" does not prove behaviour on a device.

| Compiles | Refused |
|---|---|
| Keychain, WebSocket, CryptoKit | `CBPeripheralManager` at compile time, though it works through the runtime |
| `CBCentralManager` | CoreMotion |
| `AVSpeechSynthesizer` | `UIDevice.batteryLevel` |
| `AVQueuePlayer`, `AVPlayerLooper`, `AVPlayerLayer` | `UIScreen.brightness` |
| `AVCaptureSession` and `AVCaptureDevice` | `UIImpactFeedbackGenerator` |
| `CLLocationManager` | MessageUI |
| Bonjour through `NWBrowser` | WidgetKit |
| `isIdleTimerDisabled`, `NSUbiquitousKeyValueStore` | `PhotosPicker` |
| Top Shelf (`TVTopShelfContentProvider`) | `TextEditor` |
| `TextField` | `AVAudioSession.requestRecordPermission` |

`AVCaptureDevice.setTorchModeOn` and `kSystemSoundID_Vibrate` also compile, but an Apple TV has neither a flash nor a vibration motor.

## What reuses the iPhone and iPad code

These compile for tvOS unchanged: `DeviceIdentity`, `BLEFraming`, `PairingCrypto`, `NoiseXX`, `NoiseWire`, `MuseChatTimeline` and `CredentialStore`.

These needed a change in the proof:

| File | Change |
|---|---|
| `MusePeripheral` | Replaced by `TVMusePeripheral.swift` |
| `PairingCoordinator` | `CurrentWiFi` replaced by the placeholder, and the CaptiveNetwork import removed |
| `MuseRuntime` | `model_id` is `appletv` |
| `IOSCommandRegistry` | Only the registry is kept. `defaultRegistry` depends on services tvOS lacks |

`DeviceIdentity.displayName` needs its UIKit extension too. It lives in `AppEnvironment.swift`, which the proof does not include. Without it, `identity.displayName` still compiles, because it then refers to the method, and the app crashes during registration with `Invalid type in JSON write (__SwiftValue)`. That happened once, so the proof has its own copy.

The app's interface does not carry over. `MuseAppView` relies on `TextEditor`, `PhotosPicker` and touch, so a television needs its own screens built around the remote.

## Routes that were tried

| Route | Result |
|---|---|
| Scanning as a Bluetooth client, as the owner suggested | Works from an app. It found 97 nearby devices in about 100 seconds |
| Seeing the Muse app in that scan | No. With the add-gadget screen open, the setup service was not advertised and nothing named Muse appeared. This matches the SDK: the gadget advertises, and the Muse app looks for it |
| Bluetooth transfer from an iPad to the Apple TV | Works. 4096 test bytes in about 0.75 s, in 3 of 3 rounds, found in about 0.2 s, and the data matched. It is the fallback below |
| Advertising through the runtime | **Works, and is the route to use** |

### Fallback if App Review refuses the runtime calls

Pal Again on an iPhone or iPad could pair on behalf of the Apple TV and hand it the credentials over Bluetooth, since the transfer above works. It would use public APIs only, but it needs a second device once, and the credentials must then be encrypted under a key tied to a code on the television. It has not been built, and whether Muse accepts a gadget paired this way is unknown.

## Not verified

- Speech through the television.
- Avatar video on the Apple TV (4th generation). This is the largest technical unknown, because Muse's files reach 1600×1600. It decides how far the avatar can go on this model.
- Stability and token rotation over days. About two and a half minutes after registering, the connection to the VM ended with an error whose cause was not looked into. The app reconnected and registered again by itself within 6 seconds, and the caption command arrived after that.
- Removal from Muse (`link.unpaired`).
- Behaviour when the app leaves the screen. It is expected to be the same as on iPhone: iOS and tvOS suspend apps.
- Any Apple TV other than the 4th generation, and any tvOS version other than the one on the test device.
- App Review.

## Decisions so far

- **One App Store listing.** The Apple TV app shares the listing and purchase with iPhone and iPad. Each platform has its own version and its own review, so a refused tvOS version leaves the iPhone and iPad app alone.
- **Scope.** A large Muse screen: avatar, speech, cards, timers, images, and a simple chat. There are no voice notes at the start.
- **The peripheral code stays out of the iOS build.** The iPhone and iPad app does not need it.
- **No Xcode Cloud workflow for now.** The owner asked for this so that nothing gets in the way while version 1.0 is under review.
- **Not started.** No Apple TV target exists in the main project.

## When work resumes

1. Check avatar video on the Apple TV (4th generation), since the result may change the plan.
2. Move the shared protocol code so both platforms use one copy instead of the copies in `Proof`.
3. Add a tvOS target that shares the bundle identifier, for one purchase across devices.
4. Build the screens for the remote, and an explanation of the Wi-Fi step.
5. Add a separate Xcode Cloud workflow for tvOS with manual start only, one workflow per platform.
6. Prepare tvOS screenshots and App Review notes that state plainly how Bluetooth is used.

## Running the proof

```sh
cd Docs/AppleTV/Proof
xcodebuild -project TVProbe.xcodeproj -target TVProbe -configuration Debug \
  -sdk appletvos -allowProvisioningUpdates SYMROOT="$PWD/build" build
xcrun devicectl device install app --device <APPLE_TV_UDID> build/Debug-appletvos/TVProbe.app
xcrun devicectl device process launch --console --device <APPLE_TV_UDID> com.exrector.PalAgainTVProbe
```

Enter an SDK Token on the television, using the keyboard in the iPhone's Remote app, then choose **Save and pair**. In the Muse app, find the gadget named on screen and choose `Apple TV network` at the Wi-Fi step. Do not leave a build folder here.

`Proof/Probe` holds copies of the app's sources from commit `f638660`, with the changes listed above. `Proof/ExternalCheckFromIPad.swift.txt` is the small iPad app that confirmed the gadget service from outside. It needs a `Shared.swift` with a `Handoff.log` helper, and it is kept as text so that nothing tries to compile it.

## Left on the developer's account and devices

- The Apple TV is registered as a development device.
- Two test bundle identifiers exist: `com.exrector.PalAgainTVProbe` and `com.exrector.PalAgainBLESender`.
- The test apps are installed on the Apple TV and the iPad, under the names `Pal Again TV` and `BT Sender`. They can be deleted at any time.
- The test gadget is paired in Muse, and it can be removed there.
