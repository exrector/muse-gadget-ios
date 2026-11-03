# Building and installing

The app is not on the App Store, so you build it yourself on a Mac and install it on your own device.

## What you need

- A Mac with Xcode. The app has been developed with Xcode 27, and CI builds it on `macos-15`.
- An Apple ID added to Xcode under Settings > Accounts.
- A gadget: iPhone or iPad with iOS or iPadOS 15 or newer. Bluetooth pairing does not work in Simulator, so you need a real device.

## Get the code

```sh
git clone --recurse-submodules https://github.com/exrector/muse-gadget-ios.git
cd muse-gadget-ios
```

`Vendor/muse-gadget-sdk` is the official SDK, used as a reference for the protocol. It is not compiled into the app.

## Set your signing identity

The project contains the maintainer's team and bundle ID, so change them to your own:

1. Open `MuseGadgetLegacy.xcodeproj`.
2. Select the `MuseGadgetLegacy` target, then **Signing & Capabilities**.
3. Pick your **Team** and enter your own **Bundle Identifier**, such as `com.yourname.MuseGadget`.
4. Do the same for the `MuseGadgetLegacyTests` target if you will run tests on a device.

The app declares two capabilities in `App/MuseGadgetLegacy.entitlements`:

| Capability | Used for | Without it |
|---|---|---|
| Access Wi-Fi Information | Filling in the network name during pairing | Muse shows only **Other** for Wi-Fi, and you type the name by hand |
| iCloud, key-value storage | Syncing chat text between devices | The chat stays on each device |

A free Apple ID does not offer every capability. If Xcode reports one as unavailable, remove its key from the entitlements file. Apps signed with a free Apple ID also stop launching after about 7 days until you install them again.

Keep your team and bundle ID the same between updates. The Keychain items holding your token and pairing belong to that identity, and changing it means setting the gadget up again.

## Install from Xcode

1. Connect the device and choose it as the run destination.
2. On iOS 16 or newer, turn on Developer Mode under Settings > Privacy & Security.
3. Run the `MuseGadgetLegacy` scheme.
4. If iOS refuses to open the app, trust your certificate under Settings > General > VPN & Device Management.

Installing over an existing copy keeps your token, pairing and chat history. Deleting the app removes the history.

## Install on an older device from the command line

Recent versions of Xcode may not offer a device on an old iOS as a run destination, which is what happened with an iPhone 6s on iOS 15.8.8. You can still build for it and install with `libimobiledevice`.

```sh
brew install libimobiledevice ideviceinstaller
```

Your provisioning profile has to include the device. Build, using your own values:

```sh
xcodebuild \
  -project MuseGadgetLegacy.xcodeproj \
  -scheme MuseGadgetLegacy \
  -configuration Debug \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/device \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  PRODUCT_BUNDLE_IDENTIFIER=com.yourname.MuseGadget \
  CODE_SIGN_IDENTITY='YOUR SIGNING IDENTITY' \
  PROVISIONING_PROFILE_SPECIFIER='YOUR PROFILE NAME' \
  build
```

Package it as an IPA:

```sh
mkdir -p build/ipa/Payload
ditto build/device/Build/Products/Debug-iphoneos/MuseGadgetLegacy.app build/ipa/Payload/MuseGadgetLegacy.app
(cd build/ipa && ditto -c -k --sequesterRsrc --keepParent Payload MuseGadget.ipa)
```

Find the device's ID and install. `upgrade` keeps your data:

```sh
idevice_id -l
```

```sh
ideviceinstaller -u YOUR_DEVICE_ID -w upgrade build/ipa/MuseGadget.ipa
```

Open the app by tapping its icon on the device. Starting it from the Mac is not available without a developer disk image for that iOS version.

To read the app's log over USB:

```sh
idevicesyslog -u YOUR_DEVICE_ID -p MuseGadgetLegacy
```

## Put a token on the device over USB

Pasting a long token on a small screen can be awkward, and Universal Clipboard does not work between different Apple IDs. The app can import it from a file instead:

1. Create a file named exactly `muse-sdk-import.musetoken`, containing only your token.
2. In Finder, select the device, open **Files**, and drag the file onto Muse Gadget.
3. Close the app fully and open it again. It moves the token into the Keychain and deletes the file.

Delete your copy on the Mac too.

## Tests

Protocol checks that need no device:

```sh
./Tools/run-protocol-smoke.sh
```

Unit tests in Simulator, replacing the device name with one you have:

```sh
xcodebuild test \
  -project MuseGadgetLegacy.xcodeproj \
  -scheme MuseGadgetLegacy \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

`testTwoGadgetsExchangeHistoryOverTheNetwork` uses real sockets and Bonjour on your Mac. The first run after a rebuild can take about 25 seconds, while the app's reconnect logic recovers from a stalled connection.

Debug builds accept a `--history-only` launch argument, which opens the chat without a pairing. It is for checking iCloud sync on a device that cannot be a gadget, such as the phone running the Muse app. Once set, it stays on until you delete the app, and it is not part of release builds.

```sh
xcrun devicectl device process launch --device YOUR_DEVICE_ID YOUR_BUNDLE_ID -- --history-only
```

## Project layout

| Path | Contents |
|---|---|
| `App/Sources/Bluetooth` | Pairing over Bluetooth LE |
| `App/Sources/Protocol` | Pairing crypto, Noise XX, Muse wire format, the runtime and chat rules |
| `App/Sources/Commands` | Command registry, native services, approvals, Shortcuts, local network |
| `App/Sources/Services` | Keychain, permissions, chat history, iCloud and Wi-Fi sync |
| `App/Sources/UI` | SwiftUI screens |
| `Tests` | Unit tests, including byte vectors from the official SDK |
| `Docs` | This documentation and the [protocol status](PROTOCOL-STATUS.md) |
| `Vendor/muse-gadget-sdk` | Official SDK, as a pinned submodule |

Before changing protocol code, read [AGENTS.md](../AGENTS.md) and compare your change with the SDK.

## Keep secrets out of the repository

Never commit an SDK token, device tokens, signing keys, provisioning profiles or conversations. See [SECURITY.md](../SECURITY.md).
