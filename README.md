# Muse Gadget for iOS and iPadOS

An unofficial, open-source Muse community gadget that turns an older iPhone or iPad into a screen, microphone, speaker, camera and sensor companion for Muse.

The project is a native SwiftUI application targeting iOS/iPadOS 15 or newer. Bluetooth LE is used only for the user-initiated Muse pairing flow. After pairing, the runtime uses the device's existing Internet connection and the same encrypted Noise and Link protocols as the official Muse Gadget SDK.

> This is an independent community project. It is not made by, endorsed by, or supported by Meta. Muse Gadget SDK tokens are governed separately by the [Muse Gadget SDK Token Terms](https://gadgets.muse.ai/sdk-terms).

## Current status

The repository contains a buildable native application skeleton and the first real protocol pieces:

- stable `MuseGadgetXXXXXX` identity;
- Keychain storage for the user's SDK token and device credentials;
- CoreBluetooth peripheral with the official setup service and RX/TX characteristics;
- official BLE chunk framing;
- community pairing v5 cryptography (P-256, HKDF-SHA256, AES-256-GCM);
- `get_device_info`, encrypted confirmation, Wi-Fi-current-connection provisioning and credential persistence;
- five-step guided setup with one-tap clipboard import for the SDK token;
- permission center for Bluetooth, local network, camera, microphone, speech, location and motion;
- automatic current Wi-Fi name detection with a manual SSID-only fallback (iOS does not expose saved Wi-Fi passwords to apps);
- explicit iOS command registry with no shell or arbitrary filesystem access;
- Noise XX (`25519_AESGCM_SHA256`) over WebSocket, the Muse protobuf envelope and `/link-control` framing;
- VM discovery plus `link.register`, `link.invoke`, `link.result` and `link.unpaired` handling;
- chat SwiftUI home, capabilities catalog and settings; technical diagnostics stay collapsed by default.
- chat history stored on the device, up to the latest 200 messages and excluded from backups; it can be cleared in Settings;
- optional chat text sync between devices on one Apple ID through iCloud key-value storage, on by default and switchable in Settings; photos stay on the device that took them;
- optional chat text sync directly between gadgets on one Wi-Fi network, for devices on different Apple IDs: Bonjour discovery, ChaCha20-Poly1305 with a key derived from the shared SDK token, off by default until it is verified between devices;
- a Settings choice between tap-to-record and hold-to-record for voice notes.

BLE pairing, credential persistence, VM discovery, Noise XX and `link.register` have been verified end to end on a physical iPhone 6s running iOS 15.8.8. A real Muse VM acknowledged the registration on 2026-11-03.

Text chat, photos, voice notes, device token rotation and automatic reconnect were also verified on the same iPhone 6s on 2026-11-03.

Implemented, not yet confirmed end to end on a device:

- native `camera.capture`, `location.current`, `motion.snapshot`, `voice.record`, `audio.speak`, `torch.set`, `display.set_brightness` and `display.show_card` commands, available only while the app is visible;
- `shortcuts.run`, which opens Apple Shortcuts through `x-callback-url` and returns the result; each new shortcut name needs an on-screen approval;
- `lan.discover` (Bonjour, service types declared in `Info.plist`) and `lan.request` (HTTP and HTTPS to private IPv4 and `.local` hosts); each new host and port needs an on-screen approval, certificates are pinned on first use and redirects are not followed.

Still to be done:

- spoken replies, realtime voice and avatar rendering;
- other local network protocols used by some device skills: WebSocket, MQTT, UDP and SSDP (which also needs Apple's multicast entitlement);
- an SSH client for routers and NAS devices, postponed to a later release on purpose;
- syncing photos between devices;
- reliable behavior while the screen is locked; the app keeps the screen awake by default, and this can be turned off in Settings;
- App Store release hardening and localization.

The application reports the Muse VM as connected only after the server acknowledges `link.register`.

## Build

1. Open `MuseGadgetLegacy.xcodeproj` in Xcode.
2. Choose your Apple development team and a physical iPhone or iPad. CoreBluetooth peripheral advertising cannot be validated in Simulator.
3. Build and run the `MuseGadgetLegacy` scheme.
4. In the app, save your own `mgst_…` SDK token and tap **Start pairing**.
5. In Muse on another phone, enable Developer Mode and add the displayed `MuseGadgetXXXXXX` device. The phone that runs the Muse app cannot pair itself as a gadget: it does not see its own Bluetooth advertising.

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

