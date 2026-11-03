# Protocol implementation status

| Layer | Status | Evidence required |
|---|---|---|
| Stable device identity | Implemented | Name and node suffix remain stable across launches |
| BLE GATT peripheral | Verified on iPhone 6s, iOS 15.8.8 | Muse discovers exact gadget name |
| BLE chunk framing | Implemented | Upstream vectors and live long-message exchange |
| Pairing v5 crypto | Implemented, needs vector/live tests | Encrypted client-finished accepted |
| Provisioning | Verified on iPhone 6s, iOS 15.8.8 | Device credentials received and saved; `auth_ok` observed |
| VM discovery | Verified on iPhone 6s, iOS 15.8.8 | Real API response |
| Token rotation and reconnect | Verified on iPhone 6s, iOS 15.8.8, 2026-11-03: `Device token rotated`, then `Registered with Muse`; automatic recovery after a failed ping | Long-running stability still to be observed |
| Noise XX transport | Verified on iPhone 6s, iOS 15.8.8 | `Noise session established` equivalent |
| Link control | `link.register` ACK and a `haptics.impact` invoke and result verified on iPhone 6s | Each remaining command from a real invoke |
| Text chat | Verified on iPhone 6s, iOS 15.8.8, 2026-11-03 | Reply from Muse visible in the app |
| Photo and voice notes | Verified on iPhone 6s, iOS 15.8.8, 2026-11-03 | Muse answers about the sent photo or recording |
| Native commands (camera, location, motion, speech) | Implemented, awaiting live check | `link.result` for each command from a real invoke |
| Spoken replies, realtime voice, avatar | Planned | Actual bidirectional user-visible delivery |
| Second gadget on the same SDK token | Paired on iPad (6th generation), iPadOS 17.7.11, 2026-11-03, by the owner's report | iPhone 6s stays connected afterwards |
| Haptics on iPhone 6s and older | Open: `kSystemSoundID_Vibrate` is called on iPhone 6s, but no vibration is felt; the motor itself works | The device physically vibrates on `haptics.impact` |
| Haptics on iPad | Not supported by the hardware; returns `haptics_unavailable` | — |
| Local network commands | Permission only | Real discovery and an allowlisted device command |

