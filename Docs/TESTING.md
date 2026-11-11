# Test Pal Again

Pal Again is [available on the App Store](https://apps.apple.com/us/app/pal-again/id6830354776), and new builds are tested on real older Apple devices before each release. The current confirmed baseline is iPhone 6s on iOS 15.8.8 and iPad (6th generation) on iPadOS 17.7.11. These are the oldest devices we have, not a known limit. The app can be installed on iOS or iPadOS 15 or newer, and a report from any other device, working or not, lets us add it to the description.

## Join the beta

Join through the public [TestFlight link](https://testflight.apple.com/join/jWYJWgHz) to get builds before they reach the App Store. TestFlight itself can no longer be installed on iOS or iPadOS older than 16, unfortunately. If it is already on an iOS 15 device such as the iPhone 6s, it keeps working, so do not delete it. Otherwise use the App Store version there. You can also build the current `main` branch by following [BUILDING.md](BUILDING.md).

## What to test

- onboarding and permission explanations;
- pairing from Muse Developer Mode;
- reconnecting after relaunch or network changes;
- text, photo and voice chat;
- incoming captions and Muse cards/widgets;
- Light and Dark Mode, Dynamic Type and keyboard behavior;
- camera, location, motion, speech, flashlight, brightness, Shortcuts and approved local-network commands.

Report results in [GitHub Issues](https://github.com/exrector/muse-gadget-ios/issues). Include the device model, OS version and exact steps. Never attach an SDK Token, pairing record or private chat content.
