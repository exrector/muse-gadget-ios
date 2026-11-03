# AGENTS.md

## Project location

This is the canonical checkout. Keep the project in `/Users/exrector/Documents/PROJECTS/muse-gadget-ios`; never move active development into a Codex session, history or archive directory.

## Before changing protocol code

1. Read `README.md`, `SECURITY.md` and `Docs/PROTOCOL-STATUS.md`.
2. Compare behavior with the pinned official SDK in `Vendor/muse-gadget-sdk`.
3. Never copy credentials or profiles from `/Users/exrector/Documents/PROJECTS/museSDK`.

## Non-negotiable rules

- Never commit SDK tokens, device tokens, Apple signing credentials or user conversations.
- Do not claim pairing, VM registration, command delivery, chat or voice works without live end-to-end evidence.
- BLE is a temporary pairing transport. Daily runtime must not depend on proximity to the phone that runs Muse.
- iOS commands are an explicit allowlist. Do not emulate Linux `system.run`, arbitrary `file.read` or `file.write`.
- A remote command never gains reach on its own: each new Shortcut name and each new local host and port needs a tap on the device, and `lan.request` stays limited to private IPv4 and `.local` hosts.
- Protected iOS capabilities require user-granted permissions and must fail closed.
- Preserve Apache 2.0 headers and notices when adapting upstream code.

## Verification

```sh
./Tools/run-protocol-smoke.sh

xcodebuild \
  -project MuseGadgetLegacy.xcodeproj \
  -scheme MuseGadgetLegacy \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/muse-gadget-ios-derived \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

Xcode 27 no longer accepts iOS 13 as a build target; a local compile may temporarily override `IPHONEOS_DEPLOYMENT_TARGET=15.0`. That proves current-SDK compilation only. Keep a separate older-Xcode/CI check before claiming iOS 13 compatibility.
