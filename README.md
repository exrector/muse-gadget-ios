# Muse Gadget Legacy for iOS and iPadOS

An unofficial, open-source Muse community gadget that turns an older iPhone or iPad into a screen, microphone, speaker, camera and sensor companion for Muse.

The project is native UIKit and currently targets iOS/iPadOS 13 or newer. Bluetooth LE is used only for the user-initiated Muse pairing flow. After pairing, the intended runtime transport is the device's existing Internet connection, using the same encrypted Noise and Link protocols as the official Muse Gadget SDK.

> This is an independent community project. It is not made by, endorsed by, or supported by Meta. Muse Gadget SDK tokens are governed separately by the [Muse Gadget SDK Token Terms](https://gadgets.muse.ai/sdk-terms).

## Current status

The repository contains a buildable native application skeleton and the first real protocol pieces:

- stable `MuseGadgetXXXXXX` identity;
- Keychain storage for the user's SDK token and device credentials;
- CoreBluetooth peripheral with the official setup service and RX/TX characteristics;
- official BLE chunk framing;
- community pairing v5 cryptography (P-256, HKDF-SHA256, AES-256-GCM);
- `get_device_info`, encrypted confirmation, Wi-Fi-current-connection provisioning and credential persistence;
- permission center for camera, microphone, speech and location;
- explicit iOS command registry with no shell or arbitrary filesystem access;
- UIKit diagnostics dashboard showing every setup stage.

Still to be completed and verified on a real Muse account:

- live Muse app discovery and end-to-end provisioning;
- VM discovery, token rotation and Noise/WebSocket session;
- `link.register`, `link.invoke` and `link.result` against a real VM;
- chat, voice notes, avatar rendering and camera delivery;
- reliable behavior while the screen is locked;
- lowering the deployment target below iOS 13.

No successful pairing is claimed until the real app shows the device, the gadget receives and stores device credentials, and the Wi-Fi-only runtime registers with a Muse VM.

## Build

1. Open `MuseGadgetLegacy.xcodeproj` in Xcode.
2. Choose your Apple development team and a physical iPhone or iPad. CoreBluetooth peripheral advertising cannot be validated in Simulator.
3. Build and run the `MuseGadgetLegacy` scheme.
4. In the app, save your own `mgst_…` SDK token and tap **Start pairing**.
5. In Muse on another phone, enable Developer Mode and add the displayed `MuseGadgetXXXXXX` device.

Never commit an SDK token or paired-device credentials. The app stores them in the iOS Keychain.

For a simulator-only compile check:

```sh
xcodebuild \
  -project MuseGadgetLegacy.xcodeproj \
  -scheme MuseGadgetLegacy \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Upstream reference

`Vendor/muse-gadget-sdk` is a pinned git submodule of the official [facebookincubator/muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk). The iOS code is a native port; the Linux Python package is not embedded in the application.

Clone with:

```sh
git clone --recurse-submodules https://github.com/exrector/muse-gadget-ios.git
```

## License

Apache License 2.0. See `LICENSE` and `NOTICE`. Upstream source retains its own notices. Muse service and SDK token access are subject to Meta's separate terms.

