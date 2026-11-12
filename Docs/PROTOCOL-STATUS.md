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
| Native commands (camera, location, motion, speech) | Camera, motion, speech and remote voice recording verified on iPad (6th generation), 2026-11-05. `location.current` twice returned `location_failed` after permission and foreground gates passed | Preserve the underlying Core Location error domain/code, then diagnose one further failure |
| Spoken replies to text messages | Muse TTS was tested live on iPad, 2026-11-05. A voice-modality turn returned only Muse's server fallback, although its fallback MP3 downloaded successfully (HTTP 200, 37,056 bytes). A normal text reply could not be converted afterward: both `/api/voice/tts-stream` and `/voice/tts-stream` rejected its message ID (HTTP 400, 120 bytes). Text chat therefore stays text-only and the broken user-facing toggle was removed | Re-test only after the server supports TTS for a successful text reply or voice-modality stops returning the fallback |
| Live voice conversation (2.0) | Verified on iPad (6th generation), iPadOS 17.7.11, and iPhone 6s, iOS 15.8.8, 2026-11-11 and 2026-11-12: `POST /voice/realtime` over the Noise session with `app_id=hatch-web`, 24 kHz PCM16, connects in about 2 s, Muse answers by voice on the loudspeaker. On the iPad the first sentence and a 15-second second one were accepted with no suppression once the `mcu-wearable` hint was dropped | The first sentence on iPhone 6s; long conversations |
| Video call with Muse's avatar (2.0) | Verified on iPad (6th generation), 2026-11-12: JOIN accepted, STUN over UDP in 237 ms, a 90-second call at about 1 Mbit/s with no SRTP or decode errors, Muse's face talking in sync. iPhone 6s, iOS 15.8.8, 2026-11-12: a call over UDP connected in 2.7 s and showed 852 of 853 frames; turning the phone mid-call changed nothing. Details in [VIDEO-CALLS-PLAN.md](VIDEO-CALLS-PLAN.md) | Calls over the TCP fallback on a network that blocks UDP |
| Streaming dictation | Refused by the server, 2026-11-11: `/api/voice/dictation` returns HTTP 403. Not offered | Re-test when the VM has speech recognition behind it |
| Reset App (2.0) | Simulator, 2026-11-12: files, settings and the device identity removed and the first setup step shown without a restart. By the owner's report, 2026-11-12, it works on a device | Pairing again from a reset gadget, written down step by step |
| Back in the setup guide (2.0) | iPad (6th generation), 2026-11-12: **Run Guided Setup Again** on a paired gadget showed **Back** beside the step counter; tapping it returned to Settings with the pairing and the VM connection unchanged | The same on iPhone 6s |
| Describing the gadget (2.0) | iPad (6th generation), 2026-11-12: Muse accepted `link.register` with `device_family: gadget`, `model_id: pal-again-ipad` and `metadata.model_name`, then chat and the chat subscription worked as before. Asked in the chat, Muse called `device.guide` (success 9 s after the message) and retold the guide accurately, including the foreground, permission and approval rules. Unit tests check the SDK's rules for the id, the name and the guide's size | The same on iPhone 6s |
| Late replies (2.0) | iPad (6th generation), 2026-11-12: a long task's answer streamed as `delta.text_append` naming a parent that was neither the request nor its turn's messages (as in muse-gadget-sdk#273), so the live subscription could not match it. The history check found it: `/chat/history?limit=10&session_id=<side chat>` answered 200 with that chat's messages, and the answer appeared on the gadget. Unit tests: a reply to a request the gadget let go of, or to a message its turn showed, is kept, even after the next request, for up to 30 minutes. Port of the ESP32 rules in b4bee64, except one: iPad (6th generation), 2026-11-12, Muse said it was idle and answered a long task about two minutes later, after the ESP32's 10-second rule had already dropped the request. That rule is gone | Matching a late answer from the live subscription |
| `delta.presentation` (2.0) | Unit tests from the shapes reported in muse-gadget-sdk#186: the kind of media and `fallback_text` are shown once. The files themselves cannot be fetched with a gadget's credential | A real presentation event from Muse |
| File route check (2.0) | A `/fs/read` of a missing file on each connection: 403 turns document exchange off in the Documents screen, any other answer leaves it on. iPad (6th generation), 2026-11-12: `File route check: refused`, so this account's server refuses the route to the gadget | The result on a server that allows the route |
| Connection timeout (2.0) | iPad (6th generation), 2026-11-12: after a drop the gadget stayed in `connecting` for over three minutes while the Mac on the same network reached Muse's server in 0.8 s; a WebSocket upgrade is not ended by URLRequest's timeout. Registration now has to finish within 30 s | A drop on a device after this change |
| Connection history and ping timeout (2.0) | iPad (6th generation), 2026-11-12: `net_wifi`, `vm_fetch`, `vm_ok`, `noise_ok`, `registered`, `chat_subscribe` recorded in order on launch. A pong missing for 15 s now ends the session and reconnects, followed by an internet check | A real silent drop on a device |
| Closing the Bluetooth pairing window | Not implemented: the log names a ten-minute window, but nothing closes it. The gadget advertises until pairing finishes or the search is stopped | A timer matching the SDK's setup window |
| Companion avatar | Product UI, not a Link payload | The SDK's ESP32 avatar is a local renderer with idle/listening/thinking/speaking/error states; Muse does not send an avatar image or avatar metadata in `link.register` |
| Apple TV as a gadget | Proof only, 2026-11-05, on Apple TV (4th generation): paired with the Muse app, registered, and showed a caption sent by Muse. See [AppleTV](AppleTV/README.md) | An app. Speech, avatar video, reconnecting and App Review are unverified |
| Second gadget on the same SDK token | Verified 2026-11-03: Muse sees iPhone 6s and iPad (6th generation) as two devices on one token | — |
| Telling apart devices that report only their model | Unit tests for the name: one that is just the model gets four characters of the device's own suffix. iPad (6th generation), 2026-11-05: shows as connected with a build that registers `model_id: "ipad"` | The new name and model as Muse sees them; two iPhones on iOS 16 or later |
| Haptics on iPhone 6s and older | Verified on iPhone 6s, iOS 15.8.8, 2026-11-03: `haptics.impact` vibrates through `kSystemSoundID_Vibrate` | An earlier attempt was not felt, cause not established |
| Haptics on iPad | Not supported by the hardware; returns `haptics_unavailable` | — |
| Flashlight | By the owner's report, 2026-11-04: `torch.set` works on iPhone 6s and returns `torch_unavailable` on iPad (6th generation), which has no flash | — |
| Brightness, card | iPad (6th generation), 2026-11-05: `display.set_brightness` returned success for 0.95 → 0.8 → 0.95; `display.clear_card` correctly returned `displayed: false` when no card was present | Visual confirmation of the brightness change |
| `GET /identity` | Refused on iPad (6th generation), 2026-11-04: HTTP 403, `route not allowed for this credential's scopes`, while chat on the same session works. The name stays «Muse» | A 200 with the agent's name |
| `display.set_avatar` | Verified on iPad (6th generation), iPadOS 17.7.11, 2026-11-04: Muse saved a PNG, the VM file was read over the Noise session, and the picture stayed in the chat header after a reinstall | The same on iPhone 6s |
| Avatar animations by state | Verified on iPad (6th generation), 2026-11-04: Muse's four animated WebP files, 720 and 960 px at 24 fps, become H.264 videos on the device, about 100 s each, and the idle video plays beside the chat. iPhone 6s reported installed by Muse. By the owner's report, 2026-11-05: the avatar's movement changes during standard actions | Smoothness on iPhone 6s |
| `display.set_name` | Verified on iPad (6th generation), 2026-11-05: accepted and displayed `KOTOBOBA` | Persistence after a restart |
| `display.play_avatar`, `display.clear_image` | Verified on iPad (6th generation), 2026-11-05: direct idle playback reported 8000 ms; image clearing returned `cleared: true` | — |
| Avatar list on the VM (`avatars.json`) | Verified 2026-11-04: iPad and iPhone 6s fetched all four files from the list by themselves | — |
| MP4 animations from Muse | Verified on iPad (6th generation), 2026-11-04: four MP4 files reported `ready: true` at once. iPhone 6s, iOS 15.8.8, 2026-11-04: all four files found in the app's storage, and the avatar moves, by the owner's report | Smoothness and switching between movements on iPhone 6s |
| Asking Muse automatically when the VM has no list | Unit tests only | A newly paired gadget getting its avatar with no action from the user |
| Pinned card through a restart | Verified on iPad (6th generation), 2026-11-04: a running timer card stayed on screen and kept counting after reinstalling | The same on iPhone 6s |
| `display.draw_file` | Verified on iPad (6th generation), 2026-11-04: `drawn: true`, image shown above the chat | The same on iPhone 6s |
| `audio.speak` | Verified on iPad (6th generation), 2026-11-04, by the owner's report | The same on iPhone 6s |
| `voice.configure` | Verified on iPad (6th generation), 2026-11-05: read 100, set 90, restored 100 | Audible comparison at two substantially different levels |
| `voice.record` | Verified on iPad (6th generation), 2026-11-05: mono 24 kHz WAV, 2085 ms, 100096 bytes | — |
| Speaking and listening states, command toasts, battery, brightness and volume controls | Implemented, awaiting live check | Seen on the device during a real invoke |
| `shortcuts.list` | Verified on iPad (6th generation), 2026-11-05: returned the one approved shortcut, `111` | — |
| `shortcuts.run` | iPad (6th generation), 2026-11-05: `111` returned `started: true`, `finished: true`, but no `result` field. Simple notification shortcuts also run on iPhone 6s | Diagnose delivery of a textual Shortcut result |
| Chat sync through iCloud | Verified from iPad to iPhone 15 Pro Max on one Apple ID, 2026-11-03, by the owner's report | The reverse direction, with both devices paired |
| Chat sync over Wi-Fi | Postponed and off by default; exchange verified between two instances over real sockets on a Mac, where the first run after a rebuild can stall for about 25 seconds before recovering | iPhone 6s and iPad show the same text history with different Apple IDs |
| `lan.discover`, `lan.request` | Verified on iPad (6th generation), 2026-11-05: discovery returned 19 Bonjour devices; an approved GET to Keenetic returned HTTP 200 and the KeeneticOS Web Panel body | — |
| `camera.capture` | Verified on iPad (6th generation), 2026-11-05: JPEG 600×800, 41838 bytes | — |
| WebSocket, MQTT, UDP, SSDP, SSH on the local network | Not implemented | — |

## Sending a report

**Send a Report** in Settings: unit tests for its text, and the Settings button seen in a simulator. Sending from a real device with a mail account has not been tried.

## Working in the background

iOS suspends an app soon after it leaves the screen, which ends its connection to Muse. The SDK has no answer to this, because ESP32 and Linux gadgets are simply always on. Measured on iPad (6th generation), iPadOS 17.7.11, on charge, 2026-11-05, with the screen on and nobody touching the device. Each run is one measurement, and "connected" means pings to the VM were answered.

| Way of staying connected | Result | Status |
|---|---|---|
| Background time from iOS | The time ran out 32 s after leaving the screen, the last ping was answered at about 20 s, and the app was suspended at 37 s. Back on screen, it registered again in about 5 s | In use |
| Picture in Picture with the avatar | The window closed by itself about 5 s after leaving the screen, cause not established. The playback session stayed active, and the app was never suspended: connected for 10 min 18 s and 3 min 9 s, when each run ended on purpose | Removed: a window that lasts seconds is no use, and what kept the app running was playback with no sound |
| Silent audio in the background | Not tried | Not used: background audio is meant for sound the person hears |
| Constant location updates | Not tried | Not used: drains the battery and shows a system indicator |
| Push notifications | Not available | Muse's server sends this app none |
| Home screen widget | Runs as a separate process with no connection to Muse, so it does not keep the app awake | In use, to show the last picture, name and card. Simulator: small, medium and large drawn with a running timer on iOS 18.6. By the owner's report, 2026-11-05: visible on iPhone 6s and iPad (6th generation). Lock screen sizes and the largest iPad size have not been looked at |

While the app is in the background, commands that must be visible still fail with `foreground_required`, as described in [COMMANDS.md](COMMANDS.md).

