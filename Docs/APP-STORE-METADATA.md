# Pal Again — App Store metadata

The App Store listing starts in English. A Russian listing can follow in a later version.

## App Store Connect fields

| Field | Value |
|---|---|
| Name | Pal Again |
| Subtitle | COGNITIVE LABS |
| Category | Utilities, then Productivity |
| Copyright | Cognitive Labs |
| Support URL | https://exrector.com/apps/support.html#palagain |
| Marketing URL | https://github.com/exrector/muse-gadget-ios |
| Privacy policy URL | https://exrector.com/apps/palagain/privacy.html |
| Support email | support@exrector.com |

## Promotional text

Give an older iPhone or iPad a new job as a gadget for your Muse: chat, voice, camera, sensors and a living avatar. Open source, with no subscription or ads.

## Keywords

`gadget,sdk,ai,assistant,companion,old,device,reuse,voice,chat,avatar,widget,open source,legacy`

## Description

Pal Again gives an older iPhone or iPad a new job: a gadget for your Muse, with a screen, microphone, speaker, camera and sensors.

WHAT THIS APP IS

Muse can work with physical gadgets, and the open-source Muse Gadget SDK defines how they connect. The SDK includes clients for ESP32 boards and for Linux. Pal Again is an independent implementation of the same protocol for iOS and iPadOS: it pairs the same way, connects the same way and answers the same kind of commands. The gadget is a device you already own, with no soldering and no terminal.

Pal Again is a client. Your assistant, your account and your conversations live with Muse. The app gives your assistant a place on your device to see, hear and speak.

WHAT IT DOES

• An avatar with your assistant's own face and name, moving as it listens, thinks and speaks
• Text chat, photos and voice notes
• Speech through the device's speaker
• Cards and captions on screen, and widgets in every size your device offers
• Commands Muse can use: camera, location, motion sensors, vibration, flashlight, screen brightness and device status
• Apple Shortcuts and local-network devices, each allowed by a tap on the device
• An explicit list of commands. iOS has no shell, so Muse cannot run arbitrary code or read arbitrary files

WHAT YOU NEED

• A different phone with the Muse app and Developer Mode. A phone running Muse cannot be its own gadget
• Your own SDK Token from gadgets.muse.ai. Pal Again does not include one
• The app open on screen. iOS suspends apps in the background, so the connection lasts about half a minute after you leave, and comes back by itself when you return. A stand and a charger suit it well

Confirmed on iPhone 6s with iOS 15.8.8 and iPad (6th generation) with iPadOS 17.7.11, the oldest devices we have to test on. It can be installed on iOS or iPadOS 15 or later, so other devices may work, but they have not been tested. We would love to hear how yours does.

YOUR DATA

Pal Again has no account, advertising, analytics or server of its own. Like a physical gadget built with the SDK, it talks directly to your Muse, and data goes there only when you or Muse use a feature. A physical gadget has its camera, microphone and sensors built in. Here iOS asks your permission first, and each feature stays off until you allow it. After that, your Muse can use it while the app is open on screen. Your token is kept in the iOS Keychain.

WHY IT COSTS SOMETHING

This is a one-time purchase, with no subscription, advertising or in-app purchases. The code is open source and free: anyone can build it from GitHub and sign it with their own developer certificate. The price is for the ready-to-install version. It covers the Apple Developer membership, signed builds and App Store delivery, testing on older hardware, and continued work on fixes and new features.

OPEN SOURCE AND SUPPORT

Pal Again: github.com/exrector/muse-gadget-ios
Muse Gadget SDK: github.com/facebookincubator/muse-gadget-sdk

Found a bug? Use Send a Report in Settings, or write to support@exrector.com.

Pal Again is an independent community project. Muse and related marks belong to their respective owners.

## App Review notes

Pal Again is an iOS and iPadOS implementation of the open-source Muse Gadget SDK:
https://github.com/facebookincubator/muse-gadget-sdk

The SDK includes clients for ESP32 and Linux. This app is the same kind of client, written natively for iOS, and its source is public:
https://github.com/exrector/muse-gadget-ios

WHY THERE IS NO DEMO ACCOUNT
Pairing needs a Muse Gadget SDK Token. It is personal to one Muse account, and its terms do not allow sharing it (https://gadgets.muse.ai/sdk-terms), so we cannot provide one. Anyone with Muse can create their own at gadgets.muse.ai. Pairing also needs a second phone with the Muse app and Developer Mode. Without pairing, you can review the guided setup and its explanations of each permission. We can send a video of the whole flow on request.

PERMISSIONS
Each one is asked for when it is first needed, and the app keeps working if it is denied.
- Bluetooth: pairing only.
- Local network: finding devices and sending requests the person allows.
- Camera and microphone: photos and voice notes the person sends, and commands from Muse while the app is open.
- Location: identifying the Wi-Fi network during pairing, and commands from Muse while the app is open.
- Motion: a short sensor reading on request from Muse.

BACKGROUND
The app declares no background modes and works only while it is open.

ENCRYPTION
The app uses standard algorithms through Apple's CryptoKit and system TLS, and contains no proprietary encryption.

PURCHASES
Paid download. There are no in-app purchases, subscriptions, advertising or analytics.

## Xcode mapping

- `CFBundleDisplayName`: `Pal Again`
- App icon set: `AppIcon`
- Current internal target and scheme: `MuseGadgetLegacy`
- Current bundle identifier: `com.exrector.MuseGadgetLegacy`

The internal target, scheme and bundle identifier intentionally remain unchanged during device development so an installed build keeps its Keychain credentials and pairing. App Store Connect owns the final store name and subtitle; before TestFlight, decide whether to keep the existing bundle identifier or perform one final migration to `com.exrector.palagain`.

## Artwork

The App Store icon is a 1024×1024 opaque PNG showing a loyal dog carrying a generic apple. The fruit is original artwork and does not reproduce Apple's corporate logo.
