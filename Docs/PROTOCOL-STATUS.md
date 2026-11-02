# Protocol implementation status

| Layer | Status | Evidence required |
|---|---|---|
| Stable device identity | Implemented | Name and node suffix remain stable across launches |
| BLE GATT peripheral | Implemented, unverified on iOS hardware | Muse discovers exact gadget name |
| BLE chunk framing | Implemented | Upstream vectors and live long-message exchange |
| Pairing v5 crypto | Implemented, needs vector/live tests | Encrypted client-finished accepted |
| Provisioning | Implemented locally | Device credentials received and saved; `auth_ok` observed |
| VM discovery/token rotation | Scaffold | Real API response and atomic token replacement |
| Noise XX transport | Scaffold | `Noise session established` equivalent |
| Link control | Scaffold | `link.register`, real invoke and result |
| Chat/voice/avatar | Planned | Actual bidirectional user-visible delivery |

