# Test Pal Again

Pal Again is [available on the App Store](https://apps.apple.com/us/app/pal-again/id6830354776), and new builds are tested on real older Apple devices before each release. The current confirmed baseline is iPhone 6s on iOS 15.8.8 and iPad (6th generation) on iPadOS 17.7.11. These are the oldest devices we have, not a known limit. The app can be installed on iOS or iPadOS 15 or newer, and a report from any other device, working or not, lets us add it to the description.

## Join the beta

Join through the public [TestFlight link](https://testflight.apple.com/join/jWYJWgHz) to get builds before they reach the App Store. TestFlight itself can no longer be installed on iOS or iPadOS older than 16, unfortunately. If it is already on an iOS 15 device such as the iPhone 6s, it keeps working, so do not delete it. Otherwise use the App Store version there. You can also build the current `main` branch by following [BUILDING.md](BUILDING.md).

**Version 2.0** with live voice and video conversations has its own [TestFlight link](https://testflight.apple.com/join/C3nYXZ7W). A build appears there after Apple's beta review. Installing it replaces Pal Again 1.x on that device, and its source is the `feature/2.0-video` branch.

## What to test

- onboarding and permission explanations;
- pairing from Muse Developer Mode;
- reconnecting after relaunch or network changes;
- text, photo and voice chat;
- incoming captions and Muse cards/widgets;
- Light and Dark Mode, Dynamic Type and keyboard behavior;
- camera, location, motion, speech, flashlight, brightness, Shortcuts and approved local-network commands.

In version 2.0, also:

- a live conversation by voice: say your first sentence right away, and note whether Muse hears it;
- a video call: whether Muse's face appears, whether its lips follow its voice, and how the sound is;
- turning the device during a call, muting, **Interrupt** and ending the call;
- **Reset App** in Settings, then setting the gadget up and pairing it again;
- **Back** in the setup guide after **Run Guided Setup Again**.

Report results in [GitHub Issues](https://github.com/exrector/muse-gadget-ios/issues). Include the device model, OS version and exact steps. Never attach an SDK Token, pairing record or private chat content.
