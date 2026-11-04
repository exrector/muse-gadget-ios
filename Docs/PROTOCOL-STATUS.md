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
| Spoken replies and realtime voice | Planned | Actual bidirectional user-visible delivery |
| Companion avatar | Product UI, not a Link payload | The SDK's ESP32 avatar is a local renderer with idle/listening/thinking/speaking/error states; Muse does not send an avatar image or avatar metadata in `link.register` |
| Second gadget on the same SDK token | Verified 2026-11-03: Muse sees iPhone 6s and iPad (6th generation) as two devices on one token | — |
| Haptics on iPhone 6s and older | Verified on iPhone 6s, iOS 15.8.8, 2026-11-03: `haptics.impact` vibrates through `kSystemSoundID_Vibrate` | An earlier attempt was not felt, cause not established |
| Haptics on iPad | Not supported by the hardware; returns `haptics_unavailable` | — |
| Flashlight | By the owner's report, 2026-11-04: `torch.set` works on iPhone 6s and returns `torch_unavailable` on iPad (6th generation), which has no flash | — |
| Brightness, card | Implemented, awaiting live check | Visible change on the device from a real invoke |
| `GET /identity` | Refused on iPad (6th generation), 2026-11-04: HTTP 403, `route not allowed for this credential's scopes`, while chat on the same session works. The name stays «Muse» | A 200 with the agent's name |
| `display.set_avatar` | Verified on iPad (6th generation), iPadOS 17.7.11, 2026-11-04: Muse saved a PNG, the VM file was read over the Noise session, and the picture stayed in the chat header after a reinstall | The same on iPhone 6s |
| Avatar animations by state | Verified on iPad (6th generation), 2026-11-04: Muse's four animated WebP files, 720 and 960 px at 24 fps, become H.264 videos on the device, about 100 s each, and the idle video plays beside the chat. iPhone 6s reported installed by Muse | The avatar visibly changing while Muse thinks and speaks; smoothness and build time on iPhone 6s |
| Avatar list on the VM (`avatars.json`) | Unit tests only | A second gadget fetching the animations without a chat message |
| Pinned card through a restart | Unit tests only | A running timer card still shown after reinstalling |
| `display.draw_file` | Verified on iPad (6th generation), 2026-11-04: `drawn: true`, image shown above the chat | The same on iPhone 6s |
| `audio.speak` | Verified on iPad (6th generation), 2026-11-04, by the owner's report | The same on iPhone 6s |
| `voice.configure` | Implemented, awaiting live check | `audio.speak` is quieter at a lower volume |
| Speaking and listening states, command toasts, battery, brightness and volume controls | Implemented, awaiting live check | Seen on the device during a real invoke |
| `shortcuts.run` | Simple notification shortcuts run on iPhone 6s, iOS 15.8.8, 2026-11-03, by the owner's report | `finished=true` and a text result reaching Muse |
| Chat sync through iCloud | Verified from iPad to iPhone 15 Pro Max on one Apple ID, 2026-11-03, by the owner's report | The reverse direction, with both devices paired |
| Chat sync over Wi-Fi | Postponed and off by default; exchange verified between two instances over real sockets on a Mac, where the first run after a rebuild can stall for about 25 seconds before recovering | iPhone 6s and iPad show the same text history with different Apple IDs |
| `lan.discover`, `lan.request` | Implemented, awaiting live check | Real devices listed; an approved device answers a real request |
| WebSocket, MQTT, UDP, SSDP, SSH on the local network | Not implemented | — |

