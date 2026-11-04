# User guide

Muse Gadget turns an iPhone or iPad you no longer use every day into a gadget for your Muse: a screen, microphone, speaker, camera and set of sensors that Muse can use, plus a chat you can type or talk into.

Pal Again follows the language and Light/Dark appearance selected in iOS. English and Russian are included; you can override the language for Pal Again in iOS Settings without changing the language of the whole device. [Руководство на русском](USER-GUIDE.ru.md).

The app is not on the App Store yet. To install it, you need to [build it yourself](BUILDING.md) with a Mac.

## What you need

- **A gadget:** an iPhone or iPad with Bluetooth. Confirmed so far on iPhone 6s with iOS 15.8.8 and iPad (6th generation) with iPadOS 17.7.11, the oldest devices we have to test on. The app can be installed on iOS or iPadOS 15 or newer, so you can try other devices. Whether it works or not, please tell us in [GitHub Issues](https://github.com/exrector/muse-gadget-ios/issues) with the device model and system version, and we will add it.
- **A main phone** with the Muse app, signed in to your Muse account. This has to be a different device: a phone running the Muse app cannot add itself as a gadget, because it does not see its own Bluetooth signal.
- **An SDK Token** from [gadgets.muse.ai](https://gadgets.muse.ai/settings/sdk-tokens), under Account > SDK tokens. It looks like `mgst_…`. Read the [SDK token terms](https://gadgets.muse.ai/sdk-terms) before you use it.

One token works for several gadgets. Muse shows each as a separate device.

## Set up the gadget

Setup is five steps, and the app walks you through them.

1. **Welcome.** Tap through the introduction.
2. **Add your token.** Open **Get a key at gadgets.muse.ai**, copy your token, come back and tap **Paste from Clipboard**. The app stores the token in the iOS Keychain and clears it from the clipboard.
3. **Permissions.** Tap each one and answer the system prompt. Bluetooth and local network are needed for pairing. The others enable the matching features, and you can leave them for later.
4. **Wi-Fi.** The app fills in your network name when iOS allows it. Otherwise, type the name. It never asks for or stores your Wi-Fi password here. Tap **Save and continue to pairing**.
5. **Pair.** Tap **Start pairing** and keep this screen open. Then, on your main phone:
   1. Open Muse and go to Settings > Devices.
   2. Turn on Developer Mode.
   3. Tap **+** and choose the name shown on the gadget, `MuseGadgetXXXXXX`. Check that the last six characters match.

When Muse asks for a Wi-Fi network and shows only **Other**, enter the exact name of the network the gadget is on, and its password if asked. The app ignores what it receives there and keeps using the connection it already has.

The chat opens when pairing finishes. Wait for **Connected to Muse VM** at the top before you try anything.

## Chat

The chat is the main screen. Messages you send here go into your main Muse chat, marked as coming from this device.

- **Text:** type and tap the arrow. While Muse works, you see a progress line.
- **Photos:** tap **+**, then **Take Photo** or **Choose from Photos**. Text you have already typed goes with the photo as its caption.
- **Voice notes:** use the microphone button, up to 40 seconds. You can choose how it works in Settings under **Voice recording**:
  - **Tap:** tap to start, tap again to send.
  - **Hold:** hold while you speak, release to send.

## What Muse can do with the gadget

Ask Muse in the chat, or from your main phone. If you have several gadgets, say which one you mean, such as "turn on the flashlight on the iPhone".

| Ask for | What happens |
|---|---|
| A caption or a card | Text appears on the gadget's screen |
| Show a picture | Muse saves it on its VM and it appears above the chat. Tap to enlarge it, or × to close it |
| Say something aloud | The gadget speaks through its speaker |
| Vibrate | iPhone vibrates. iPads have no vibration motor and report that |
| Flashlight | Turns on or off, where the device has one |
| Screen brightness | Changes the brightness |
| Take a photo | The rear camera takes a small photo |
| Where is it | Reports its location |
| Motion | Reports a single reading from the motion sensors |
| Battery and free space | Reports device health |
| Run a shortcut | Runs an Apple Shortcut by name |
| Find devices on my network | Lists devices that announce themselves on your Wi-Fi |
| Talk to a device on my network | Sends one web request to a device on your network |

Some of these have not been confirmed on a real device yet. See [what has been tested](PROTOCOL-STATUS.md).

**The gadget has to be open on screen.** iOS suspends apps in the background, so the camera, microphone, sensors and everything else stop answering once you leave the app. **Keep Screen Awake** in Settings is on by default for this reason, and a stand with a charger suits this well. A quick look at another app is fine: the connection lasts about half a minute, and the app reconnects by itself when you come back.

### Home screen widget

Touch and hold an empty spot on the home screen, tap **+**, and choose **Pal Again**. Pick a size and tap **Add Widget**. Every size your device offers is there. On iPhone with iOS 16 or newer and iPad with iPadOS 17 or newer, you can also add it to the lock screen.

The widget shows Muse's picture, its name and the current card, and a timer on a card keeps counting. Tapping it opens the app. The picture does not move, because iOS does not let widgets play video. The widget shows what the app last gave it, and it does not keep the app awake or connected.

### Muse's avatar and name

There is nothing to do. When a gadget first connects, it shows a plain mark and the name «Muse» while it asks Muse for its avatar and name by itself. That request goes to your Muse chat once. The avatar and name then appear, usually within a few minutes, and the avatar moves as Muse listens, thinks and speaks.

Your other gadgets fetch the same files from a list Muse keeps on its VM when they connect, and new movements arrive the same way. Once a file has arrived, it plays without Muse.

To update it by hand, tap **Muse name and avatar** in Settings. **Remove Avatar** removes it from that gadget only, and it stays removed until you ask again.

### Apple Shortcuts

Muse can run shortcuts from the Shortcuts app, which reaches things like the Home app, reminders and messages.

1. Create the shortcut in the Shortcuts app.
2. Ask Muse to run it by its exact name.
3. The first time, the gadget asks you to allow that name. Tap **Allow** or **Don’t Allow**. You have 20 seconds.

The screen switches to Shortcuts and comes back when it finishes. If the shortcut gives back text, Muse receives it. iOS does not let apps see your list of shortcuts, so Muse knows only the names it was told or that you have already allowed.

### Devices on your network

Muse can find devices on your Wi-Fi and send them web requests. The [skills in the Muse Gadget SDK](https://github.com/facebookincubator/muse-gadget-sdk/tree/main/skills) describe how to use many smart home devices.

- The first request to each device asks you on screen, showing its address.
- Only addresses on your own network work, never the Internet.
- Only HTTP and HTTPS work. Devices that need WebSocket, MQTT, UDP or SSDP are not supported yet.

## Settings

The gear button opens **Settings**: under the avatar on an iPad, and in the header on an iPhone. It has:

| Setting | What it does |
|---|---|
| **Permissions** | Shows what iOS has allowed, with a link to system settings |
| **Approved for Muse** | Lists shortcuts and network devices you allowed. Tap **Remove** to withdraw one |
| **Muse name and avatar** | Asks Muse to update them. They normally arrive by themselves, see [Muse's avatar and name](#muses-avatar-and-name) |
| **This device** | Battery and free space |
| **Screen brightness**, **Speech volume** | Screen brightness and how loud Muse speaks |
| **Voice recording** | Tap or hold for voice notes, and **Confirm before sending** to add a send button instead of sending as soon as you finish |
| **Chat history over Wi-Fi** | Direct sync between gadgets. Off by default, and still being tested |
| **Chat history in iCloud** | Sync through iCloud. On by default |
| **Keep Screen Awake** | Keeps the screen on while paired |
| **Diagnostics** | Technical log, including the result of each command |
| **Clear Chat History** | Deletes the saved chat |
| **Replace SDK Token** | Stores a different token |
| **Remove Muse Pairing** | Removes the pairing, after which you set the gadget up again |

## Chat history

The app keeps your latest 200 messages on the device, including small photo previews, so they are still there when you reopen it.

**iCloud sync** copies the text to your other devices on the same Apple ID, usually within a few minutes. Photos stay on the device that took them, and others show **Photo from another device**. Devices on different Apple IDs do not sync.

Clearing the history with sync on also clears it on your other synced devices. Your conversation in Muse itself stays either way. Messages Muse sends while the app is closed do not appear in the gadget, because Muse offers no way to fetch past messages.

## Privacy

- **Your token and pairing data** stay in the iOS Keychain on the device.
- **Your messages, photos and voice notes** go to Muse, encrypted in transit, when you send them.
- **Your chat text** goes to your own iCloud account if iCloud sync is on.
- **Saved history** is not included in device backups.
- **Bluetooth** is used only during pairing.
- **Remote commands** cannot start without the permission iOS already gave the app, and the app never shows a permission prompt because of a remote command.

Pairing protects your credentials from people passively listening, but it cannot stop an active attacker in the middle. Pair on a network you trust and check the `MuseGadgetXXXXXX` name. See [SECURITY.md](../SECURITY.md).

## Troubleshooting

| What you see | What to try |
|---|---|
| Muse does not find the gadget | Keep the pairing screen open on the gadget, close to the main phone, with Bluetooth on. Check that Developer Mode is on in Muse |
| Muse lists only **Other** for Wi-Fi | Type the gadget's network name and password. See [Set up the gadget](#set-up-the-gadget) |
| Muse rejects the token during pairing | Create a new token on gadgets.muse.ai and use **Replace SDK Token** |
| A long token is hard to paste on a small screen | Use the USB method in [BUILDING.md](BUILDING.md#put-a-token-on-the-device-over-usb) |
| **Connected to Muse VM** does not appear | Check the gadget's Internet connection, then look in **Diagnostics**. The app keeps retrying, waiting up to a minute between attempts |
| The app says Muse revoked the pairing | Use **Remove Muse Pairing**, then set the gadget up again |
| A command fails with `foreground_required` | Open the app on the gadget and keep it on screen |
| A command fails with `permission_required` | Allow that permission under **Permissions** |
| Vibration does nothing | Check Settings > Accessibility > Touch > Vibration on the device. iPads have no motor |
| History does not sync | Both devices need the same Apple ID, with **Chat history in iCloud** on. Open the app again to prompt a check |
