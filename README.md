# Pal Again for iOS and iPadOS

**Pal Again** is a faithful Muse AI companion that gives an older iPhone or iPad a useful second life.

> **Make Old Devices Smart Again.**

An open-source Muse community gadget that turns an older iPhone or iPad into a screen, microphone, speaker, camera and sensor companion for Muse, with a chat you can type or talk into.

> This is an independent open-source community project. Muse and related marks belong to their respective owners. Muse Gadget SDK tokens are governed separately by the [Muse Gadget SDK Token Terms](https://gadgets.muse.ai/sdk-terms).

## What it does

- **Chat with Muse** from the gadget by text, photo or voice note, with history that stays on the device.
- **A living avatar** with Muse's own face and name, moving as it listens, thinks and speaks. After pairing, tap **Muse avatar** in Settings: see the [user guide](Docs/USER-GUIDE.md#muses-avatar-and-name).
- **Guided setup** in five steps, so nobody needs a terminal to pair a device.
- **Device features Muse can use:** screen captions and cards, speech, vibration, flashlight, brightness, camera, location, motion sensors and device health.
- **Apple Shortcuts:** Muse can run shortcuts you allow, which reaches the Home app, reminders, messages and more.
- **Your local network:** Muse can find devices on your Wi-Fi and send web requests to the ones you allow.
- **History sync** between devices on one Apple ID through iCloud.
- **English and Russian interface** selected by iOS, including localized permission prompts. The per-app language can be changed in iOS Settings; there is no separate language switch inside Pal Again.
- **System appearance** with a turquoise-blue design that follows Light and Dark Mode on iOS 15 and newer.

iOS has no shell, so unlike the Linux gadget there is no `system.run`. Muse gets an explicit list of native commands, and anything new it wants to reach needs a tap on the device.

## Documentation

| Document | For |
|---|---|
| [User guide](Docs/USER-GUIDE.md) ([на русском](Docs/USER-GUIDE.ru.md)) | Setting up and using the gadget |
| [Building and installing](Docs/BUILDING.md) | Getting the app onto your device |
| [Command reference](Docs/COMMANDS.md) | What Muse can call, with parameters and errors |
| [Protocol status](Docs/PROTOCOL-STATUS.md) | What has been verified, and how |
| [Security](SECURITY.md) | Secrets, command boundaries and pairing limits |
| [Testing](Docs/TESTING.md) | Join the beta and report device-specific results |
| [Contributing](CONTRIBUTING.md) | Help improve Pal Again |
| [Privacy policy](PRIVACY.md) | What stays local and what is sent when you use Muse |

## Requirements

- iPhone or iPad with iOS or iPadOS 15 or newer, as the gadget.
- A different phone with the Muse app. A phone running Muse cannot be its own gadget, because it does not see its own Bluetooth signal.
- An SDK Token from [gadgets.muse.ai](https://gadgets.muse.ai/settings/sdk-tokens). One token can serve several gadgets.
- During the beta, a Mac with Xcode is required to build and install the app. The App Store link will be added here when the public listing is live.

## Current status

The core works on the devices below, but much of it is new and long-running stability has not been observed yet.

**Tested on:** iPhone 6s with iOS 15.8.8, and iPad (6th generation) with iPadOS 17.7.11.

| State | Features |
|---|---|
| Verified on a device | Pairing, connecting to Muse, text chat, photos, voice notes, chat history, token rotation, reconnecting, vibration, a second gadget on one token |
| Partly verified | iCloud sync (iPad to iPhone only), Apple Shortcuts (simple shortcuts, without checking a returned result) |
| Built, not yet verified on a device | Camera, location, motion, speech and flashlight commands, brightness, screen cards, local network commands, hold-to-record |
| Built, off by default | Encrypted chat sync directly between gadgets over Wi-Fi, for devices on different Apple IDs |
| Not built yet | Spoken replies, realtime voice, photo sync, an SSH client, WebSocket, MQTT, UDP and SSDP for local devices |

**The app has to stay on screen.** iOS suspends apps in the background, so the gadget answers only while open. It keeps the screen awake by default.

The app reports Muse as connected only after the server acknowledges `link.register`.

## Quick start

1. [Build and install](Docs/BUILDING.md) the app on your gadget, using your own Apple team and bundle ID.
2. Follow the steps in the app: add your token, allow permissions, confirm Wi-Fi and start pairing.
3. On your main phone, open Muse, go to Settings > Devices, turn on Developer Mode, tap **+** and choose the `MuseGadgetXXXXXX` name shown on the gadget.

The [user guide](Docs/USER-GUIDE.md) covers the details.

Never commit an SDK token or paired-device credentials. The app stores them in the iOS Keychain.

## Upstream reference

`Vendor/muse-gadget-sdk` is a pinned git submodule of the official [facebookincubator/muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk). The iOS code is a native port; the Linux Python package is not embedded in the application.

Clone with:

```sh
git clone --recurse-submodules https://github.com/exrector/muse-gadget-ios.git
```

## License

Apache License 2.0. See `LICENSE` and `NOTICE`. Upstream source retains its own notices. Muse service and SDK token access are subject to Meta's separate terms.

## App Store price and support

Pal Again will cost **$1** on the App Store. Each user supplies their own Muse Gadget SDK Token; the purchase does not sell access to Muse. The price covers a ready-to-use build, Apple signing and App Store delivery, and helps fund independent development, compatibility testing on older devices and the Apple Developer Program, which costs about $100 per year.

The source remains public so anyone can inspect it, contribute improvements or build it themselves. Buying the App Store version is the simplest way to install Pal Again and directly support continued development.

