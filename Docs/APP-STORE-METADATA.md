# Pal Again — App Store metadata

## Brand

- **App name:** Pal Again
- **Tagline:** Make Old Devices Smart Again.
- **Subtitle:** A faithful Muse AI companion
- **Positioning:** Give an older iPhone or iPad a useful second life as a screen, microphone, speaker, camera and sensor companion for Muse.

## Xcode mapping

- `CFBundleDisplayName`: `Pal Again`
- App icon set: `AppIcon`
- Current internal target and scheme: `MuseGadgetLegacy`
- Current bundle identifier: `com.exrector.MuseGadgetLegacy`

The internal target, scheme and bundle identifier intentionally remain unchanged during device development so an installed build keeps its Keychain credentials and pairing. App Store Connect owns the final store name and subtitle; before TestFlight, decide whether to keep the existing bundle identifier or perform one final migration to `com.exrector.palagain`.

## Artwork

The App Store icon is a 1024×1024 opaque PNG showing a loyal dog carrying a generic apple. The fruit is original artwork and does not reproduce Apple's corporate logo.
