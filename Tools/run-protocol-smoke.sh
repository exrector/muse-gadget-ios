#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CACHE=${TMPDIR:-/tmp}/muse-gadget-swift-module-cache
BINARY=${TMPDIR:-/tmp}/muse-gadget-protocol-smoke

cd "$ROOT"
swiftc -module-cache-path "$CACHE" \
  App/Sources/Protocol/DeviceIdentity.swift \
  App/Sources/Protocol/BLEFraming.swift \
  App/Sources/Protocol/PairingCrypto.swift \
  Tools/ProtocolSmoke/main.swift \
  -o "$BINARY"
"$BINARY"

