# ADR-0001: Independent application with pinned upstream SDK

**Status:** Accepted  
**Date:** 2026-11-02  
**Decider:** exrector

## Context

The application is an independently versioned iOS/iPadOS product, but must track the official Muse Gadget pairing and runtime protocols. It may later be proposed for inclusion in Meta's repository or community catalog.

## Decision

Maintain the application in the independent public repository `exrector/muse-gadget-ios`. Pin the official SDK as `Vendor/muse-gadget-sdk` git submodule and port only the required protocol behavior into reviewed Swift code. Do not base the public project on the private `museSDK` recovery repository.

## Consequences

- Product releases, signing and App Store metadata remain under the owner's control.
- Upstream protocol changes are explicit submodule updates, not silent copies.
- A later upstream contribution can be proposed after live pairing and runtime verification.
- The app must retain Apache 2.0 notices for adapted upstream code.

