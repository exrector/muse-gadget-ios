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
- **Settings from every setup step.** A gear in the setup guide's header opens the full Settings, including Reset App, on every step, also after removing the pairing.
- **Back** in the setup guide while a saved pairing exists, so opening the guide or starting a token replacement by accident no longer needs an app restart.
- **The gadget describes itself** as the SDK now asks: `device_family: gadget`, `model_id` `pal-again-iphone` or `pal-again-ipad`, a model name such as "iPhone 6s", and a new `device.guide` command that tells Muse what this gadget is and what it cannot do.
- **Late replies are kept**, and while one is awaited the gadget also reads the chat's history every 45 seconds, because Muse's live events for a long task may not name the request. If Muse still says it is working 20 seconds after taking a message, the gadget stops waiting and says so; the answer appears in the chat when it comes, even after the next message. **Stop** works the same way, since Muse has no way to cancel a chat reply. The request is remembered for 30 minutes. Unlike the ESP32 firmware, the gadget does not forget it 10 s after Muse says it is idle: on the iPad Muse said so and answered two minutes later.
- **The open chat shows what came from elsewhere.** A message Muse posts in the open chat that answers no message of this gadget, such as one asked for from the Muse app or in a call, makes the gadget read that chat's history a moment later, and history now reads the open side chat too (`session_id`).
- **A chat of the gadget's own.** A newly paired gadget opens a chat named after it instead of the main chat, and right after pairing it sends one message there, "This is the chat of the gadget … (Pal Again)", which creates the chat in Muse and gives it a name that says what it is. Gadgets paired before keep the chat they have.
- **Chats deleted in the Muse app leave the gadget's list.** The gadget cannot list the account's chats, so on connecting and on **Refresh Chats** it asks each chat it knows for its history; one Muse no longer has leaves the list with its messages. If that was the gadget's own chat, it gets a new one, greeted as after pairing.
- **Calls join the open chat.** A voice or video call passes the open chat as its thread, as the SDK's `--thread-id` does, instead of always going to the main chat. A chat Muse has not created yet still gets the call in the main chat.
- **Media and forms from Muse** show a line saying what Muse sent and its fallback text. Gadgets cannot fetch the files themselves (muse-gadget-sdk#186).
- **Connection history** in `device.health` and the diagnostics steps: network changes, each stage of connecting, drops, and after a silent drop whether the internet itself was reachable. Codes only, never addresses or content.

### Changed

- On an iPad a call takes the avatar's square, with its status, Muse's latest words and the buttons over the picture, so Muse's card, picture and caption stay in view. An iPhone shows the call as a card, with its own layout when the phone is on its side.
- A voice call's sentences appear in the chat as they are said. When the call ends they make way for Muse's own record of it from the chat's history.
- The confirmations for removing the pairing and for the reset say to remove the device in the Muse app too (Settings > Devices). Pairing again fails otherwise.
- The connection to Muse uses the `hatch-web` app identity only while live conversation is on. With it off, the connection is as in 1.x.

### Fixed

- The first sentence of a call is heard. Calls no longer send the SDK's `mcu-wearable` hint, which made Muse drop the opening sentences ([muse-gadget-sdk#344](https://github.com/facebookincubator/muse-gadget-sdk/issues/344)).
- Muse stays audible after an iPad is turned during a call.
- A crash when the diagnostics object was released while MetricKit still held it.
- A connection that died without an error could hang for minutes: a ping now times out after 15 seconds, and connecting has to reach registration within 30 seconds, after which the gadget reconnects.
- The Documents screen turns off exchange with Muse when Muse's server refuses the file route to the gadget, instead of failing on each try.

### Known limits

- **Calls depend on the Muse account.** Meta turns calls on or off per account; when the Muse app has no call button, the gadget's calls are refused with HTTP 404 (muse-gadget-sdk#310). Seen on 2026-11-13: calls that worked for two days stopped in the Muse app and on the gadget at once.

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
