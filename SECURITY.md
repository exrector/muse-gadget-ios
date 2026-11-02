# Security

## Secrets

- Never commit a Muse SDK token, device access token, refresh token, Apple signing key or provisioning profile.
- Runtime credentials belong in the iOS Keychain and are never printed in logs.
- The public repository must never import profiles from the private `museSDK` recovery project.

## Command boundary

The iOS gadget advertises an explicit command allowlist. It intentionally has no shell, arbitrary filesystem access, accessibility automation or hidden permission escalation. A command that needs protected data must fail until the user grants the corresponding iOS permission.

## Pairing limitation

Muse community pairing protects setup credentials from passive observers but has no manufacturer attestation and cannot prevent an active man-in-the-middle. Pair only on a trusted local network and verify the exact `MuseGadgetXXXXXX` suffix shown by the app.

Please report vulnerabilities privately to the repository owner rather than publishing credentials or exploit details in an issue.

