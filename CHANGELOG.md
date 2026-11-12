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
- **The gadget describes itself** as the SDK now asks: `device_family: gadget`, `model_id` `pal-again-iphone` or `pal-again-ipad`, a model name such as "iPhone 6s", and a new `device.guide` command that tells Muse what this gadget is and what it cannot do.
- **Late replies are kept.** If Muse still says it is working 20 seconds after taking a message, the gadget stops waiting and says so; the answer appears in the chat when it comes, even after the next message. **Stop** works the same way, since Muse has no way to cancel a chat reply. The request is remembered for 30 minutes. Unlike the ESP32 firmware, the gadget does not forget it 10 s after Muse says it is idle: on the iPad Muse said so and answered two minutes later.
- **Media and forms from Muse** show a line saying what Muse sent and its fallback text. Gadgets cannot fetch the files themselves (muse-gadget-sdk#186).
- **Connection history** in `device.health` and the diagnostics steps: network changes, each stage of connecting, drops, and after a silent drop whether the internet itself was reachable. Codes only, never addresses or content.

### Changed

- On an iPad a call covers the avatar panel beside the chat. An iPhone shows it as a card, with its own layout when the phone is on its side.
- The confirmations for removing the pairing and for the reset say to remove the device in the Muse app too (Settings > Devices). Pairing again fails otherwise.
- The connection to Muse uses the `hatch-web` app identity only while live conversation is on. With it off, the connection is as in 1.x.

### Fixed

- The first sentence of a call is heard. Calls no longer send the SDK's `mcu-wearable` hint, which made Muse drop the opening sentences ([muse-gadget-sdk#344](https://github.com/facebookincubator/muse-gadget-sdk/issues/344)).
- Muse stays audible after an iPad is turned during a call.
- A crash when the diagnostics object was released while MetricKit still held it.
- A connection that died without an error could hang for minutes: a ping now times out after 15 seconds and the gadget reconnects.
- The Documents screen turns off exchange with Muse when Muse's server refuses the file route to the gadget, instead of failing on each try.

### Known limits

- Calls are half duplex: the microphone is closed while Muse speaks. **Interrupt** stops the answer.
- Streaming dictation is refused by the server and is not offered.
- Text replies are not read aloud.
- Muse's audio, video and images cannot be played on the gadget: only their description is shown.
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
