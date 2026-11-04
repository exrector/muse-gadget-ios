# Contributing to Pal Again

Pal Again exists to give older iPhones and iPads a useful second life. Contributions are welcome: code, device testing, translations, accessibility reviews, documentation and reproducible bug reports all help.

## Before opening a pull request

1. Read [BUILDING.md](Docs/BUILDING.md) and build the current `main` branch.
2. Never commit an SDK Token, pairing credential, Apple signing certificate or personal chat data.
3. Keep the deployment target at iOS 15 unless a change is explicitly discussed.
4. Preserve English and Russian localization for user-facing text.
5. Run the test suite and describe the physical device and OS version used for verification.

## Report a bug or propose a feature

Open a [GitHub issue](https://github.com/exrector/muse-gadget-ios/issues) with the device model, OS version, the exact action performed and the visible result. Redact tokens, account identifiers and private conversation content.

For protocol work, link the relevant upstream Muse Gadget SDK behavior and state clearly whether the result was verified on a physical device.
