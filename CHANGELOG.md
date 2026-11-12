# Changelog

What changed in each version of Pal Again. Device checks are listed in [Docs/PROTOCOL-STATUS.md](Docs/PROTOCOL-STATUS.md).

## 2.0 (beta in TestFlight, branch `feature/2.0-video`)

Tested through its own [TestFlight link](https://testflight.apple.com/join/C3nYXZ7W). Installing it replaces Pal Again 1.x on that device.

### Added

- **Live Conversation with Muse (Beta).** A phone button beside the microphone opens a hands-free conversation: you speak and Muse answers in its own voice. It can be muted, interrupted and ended, and ends by itself after 45 seconds of silence or 15 minutes.
- **Video with Muse's Avatar (Beta)**, on by default while live conversation is on. The conversation becomes a video call through Meta's media server for Muse, about 1 Mbit/s, and Muse's face talks in sync with its voice.
- **Muse Greets First**, on by default: Muse says hello once the conversation is connected.
- **Short Replies to Voice**, on by default: Muse answers voice notes briefly, in plain sentences.
- **Reset App** in Settings removes the SDK token, the pairing, the chat, the avatar, files, access granted to Muse, settings and the device identity, and opens the first setup step. iOS permissions stay, because only iOS Settings can change them.
- **Back** in the setup guide while a saved pairing exists, so opening the guide or starting a token replacement by accident no longer needs an app restart.

### Changed

- On an iPad a call covers the avatar panel beside the chat. An iPhone shows it as a card, with its own layout when the phone is on its side.
- The confirmations for removing the pairing and for the reset say to remove the device in the Muse app too (Settings > Devices). Pairing again fails otherwise.
- The connection to Muse uses the `hatch-web` app identity only while live conversation is on. With it off, the connection is as in 1.x.

### Fixed

- The first sentence of a call is heard. Calls no longer send the SDK's `mcu-wearable` hint, which made Muse drop the opening sentences ([muse-gadget-sdk#344](https://github.com/facebookincubator/muse-gadget-sdk/issues/344)).
- Muse stays audible after an iPad is turned during a call.
- A crash when the diagnostics object was released while MetricKit still held it.

### Known limits

- Calls are half duplex: the microphone is closed while Muse speaks. **Interrupt** stops the answer.
- Streaming dictation is refused by the server and is not offered.
- Text replies are not read aloud.
- The Bluetooth pairing window does not close by itself after ten minutes. Leave step 5 or tap **Stop searching** to close it.

## 1.0.2 (TestFlight beta, 2026-11-11)

The same code as 1.0.1 under the next version number, so it can be tested while 1.0.1 waits for App Review.

## 1.0.1 (submitted to the App Store, 2026-11-11)

- Fixed a crash that stopped pairing at step 5 on every device in 1.0.
- A reinstalled app no longer picks up the SDK token and pairing left in the Keychain by the previous install.
- The confirmation for removing the pairing now appears on iPad.
- Optional crash diagnostics: Apple MetricKit crash and hang reports with safe app-flow steps, off until you agree.
- TestFlight builds show a beta label.

## 1.0 (App Store, November 2026)

The first release: guided setup, pairing with Muse over Bluetooth, chat by text, photo and voice note, Muse's avatar and name, widgets, native device commands, Apple Shortcuts, local network requests and chat history sync through iCloud.
