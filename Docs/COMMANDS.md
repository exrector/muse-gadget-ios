# Command reference

These are the commands the gadget registers with Muse through `link.register`. Muse calls them with `link.invoke` and gets the answer in `link.result`. For which ones have been confirmed on real devices, see [PROTOCOL-STATUS.md](PROTOCOL-STATUS.md).

The set is an explicit allowlist, defined in [`IOSCommandRegistry.swift`](../App/Sources/Commands/IOSCommandRegistry.swift). There is deliberately no `system.run`, `file.read` or `file.write`: iOS has no shell, and App Store rules forbid running downloaded code.

## General rules

- **Visible only.** Everything except `device.health`, `display.set_caption`, `display.set_avatar`, `display.set_name`, `display.play_avatar`, `display.clear_avatar`, `display.draw_file`, `display.clear_image`, `voice.configure`, `shortcuts.list` and an already approved `lan.request` fails with `foreground_required` when the app is not on screen.
- **No remote permission prompts.** A command that needs an iOS permission fails with `permission_required` until the user has granted it in the app.
- **On-screen approval.** Each new shortcut name and each new local host and port needs a tap on the device. Waiting for it can take up to 20 seconds.
- **Timeouts.** A command answers `command_timeout` after 30 seconds, unless noted below.
- **Result size.** A `link.result` is limited to 256 KiB, and larger results fail with `payload_too_large`.

A failed command has `ok: false` and a short code in `error`.

## Device and display

### `device.health`

Reports `system`, `system_version`, `model`, `battery_percent`, `free_bytes` and `uptime_seconds`.

### `display.set_caption`

Shows a text bubble in the chat.

| Parameter | Type | Notes |
|---|---|---|
| `text` | string, required | Up to 500 bytes |

Errors: `invalid_text`.

### `display.show_card`

Shows a dismissible card, replacing any current card, so there is only ever one. It stays through restarts and reinstalls over the app, with its timer still counting, until it is cleared. On an iPad it sits beside or below Muse's avatar, and on a phone at the top of the chat.

| Parameter | Type | Notes |
|---|---|---|
| `title` | string, required | Up to 120 characters |
| `body` | string | Up to 1000 characters |

Errors: `invalid_title`, `invalid_body`.

### `display.clear_card`

Removes the card. Takes no parameters.

### `display.set_avatar`

Sets the picture shown beside Muse's name in the chat, from an image file on the VM. Muse has no route for reading an agent's avatar, so it draws the picture itself and saves it first. The app keeps it across restarts, a still picture at up to 1024 px. Times out after 180 seconds.

| Parameter | Type | Notes |
|---|---|---|
| `path` | string, required | Relative path on the VM, such as `workspace/avatar.png`, up to 32 MiB |
| `state` | string | The movement, for an animated GIF, APNG or WebP. The device plays `idle`, `listening`, `thinking` and `speaking` by itself (`working` and `talking` also work). Any other short name is a movement for `display.play_avatar`. Leave it out for a still picture |

Returns `installed`, plus `width`, `height` and `byte_count` for a still picture, or `state`, `frames`, `width`, `height` and `duration_ms` for an animation. The device turns each animation into an H.264 video once, in the background, and plays that from then on, so no later step needs Muse. A state with no animation of its own plays `idle`. Errors: `invalid_state`, `invalid_path`, `not_connected`, `file_too_large`, `file_unavailable` (with `http_status`), `read_failed`, `not_an_image`, `save_failed`. A failure leaves the current picture in place.

Muse can also list its files in `workspace/pal-again/avatars.json` on the VM, as `{"name":"Its name","animations":{"idle":{"path":"workspace/idle.webp","bytes":123}}}`. Each gadget reads the list when it connects and fetches what is new, so a new movement or a new gadget needs no chat message. After the user removes the avatar in Settings, the list is ignored until Muse sets one again.

### `display.set_name`

Sets the name shown beside the avatar, kept across restarts. Without it the app shows «Muse», because `GET /identity` is refused for this gadget's credential.

| Parameter | Type | Notes |
|---|---|---|
| `name` | string, required | One line, up to 40 characters |

Returns `name`. Errors: `invalid_name`.

### `display.play_avatar`

Plays one movement once, then the avatar goes back to what it was doing.

| Parameter | Type | Notes |
|---|---|---|
| `name` | string, required | A name given to `display.set_avatar` |

Returns `playing` and `duration_ms`. Errors: `unknown_animation`, with `available`, the movements that are ready.

### `display.clear_avatar`

Removes the picture. Takes no parameters.

### `display.draw_file`

Shows an image file from the VM in a panel above the chat, where a tap opens it across the screen. It is not kept in the chat history. Times out after 180 seconds.

Unlike the SDK's firmware there is no `display.draw_url`: fetching an address Muse supplies would give it a way to reach new hosts, including on the local network. Muse can save a picture on its VM and draw that file.

| Parameter | Type | Notes |
|---|---|---|
| `path` | string, required | Relative path on the VM, up to 32 MiB |

Returns `drawn`, `width` and `height`. Errors: `invalid_path`, `not_connected`, `file_too_large`, `file_unavailable` (with `http_status`), `read_failed`, `not_an_image`.

### `display.clear_image`

Removes the image. Takes no parameters.

### `display.set_brightness`

| Parameter | Type | Notes |
|---|---|---|
| `level` | number, required | 0.0 to 1.0 |

Returns `level` and `previous_level`. Errors: `invalid_level`.

### `torch.set`

| Parameter | Type | Notes |
|---|---|---|
| `on` | boolean, required | |
| `level` | number | 0.1 to 1.0, default 1.0 |

Returns `on`. Errors: `invalid_arguments`, `invalid_level`, `torch_unavailable` (no flashlight, as on some iPads), `torch_failed`.

### `haptics.impact`

Takes no parameters. Returns `played` and `method`:

- `impact_generator` on iPhone 7 and newer.
- `system_vibration` on iPhone 6s and older, where the impact generator silently does nothing.

iOS can ignore the system vibration depending on the device's vibration settings, so `played: true` means the request was made. iPads and iPods fail with `haptics_unavailable`.

## Audio

### `audio.speak`

Speaks text with the system voice.

| Parameter | Type | Notes |
|---|---|---|
| `text` | string, required | Up to 1000 bytes |

Returns `accepted`, `speaking` and `speech_id` as soon as speech starts. It does not wait for the end. Errors: `invalid_text`, `busy`, `audio_session_failed`.

### `voice.configure`

Sets how loud `audio.speak` is, kept across restarts. The device's volume buttons still apply on top, because iOS gives apps no way to set the system volume.

| Parameter | Type | Notes |
|---|---|---|
| `volume` | integer | 0 to 100. Without it, the command reports the current volume |

Returns `volume`. Errors: `invalid_volume`.

### `voice.record`

Records 2 seconds from the microphone, which is what fits in a `link.result`. Takes no parameters. Needs the microphone permission.

Returns `mime_type` (`audio/wav`), `data_base64`, `byte_count`, `duration_ms`, `sample_rate` (24000) and `channels` (1). Errors: `busy`, `recording_failed`, `timeout`.

## Camera and sensors

### `camera.capture`

Takes a JPEG with the rear camera, without flash. The result is at most 96 KiB and 800 px on its long side. Takes no parameters. Needs the camera permission.

Returns `mime_type`, `data_base64`, `byte_count`, `width`, `height` and `captured_at`. Errors: `unavailable`, `busy`, `capture_failed`, `timeout`.

### `location.current`

Takes one location reading, accurate to about 100 m. Takes no parameters. Needs the location permission.

Returns `latitude`, `longitude`, `horizontal_accuracy_m` and `timestamp`, plus `altitude_m` and `vertical_accuracy_m` when known. Errors: `unavailable`, `busy`, `location_failed`, `timeout`.

### `motion.snapshot`

Takes one motion reading. Takes no parameters. Needs the motion permission.

Returns `timestamp_s`, `gravity`, `user_acceleration`, `rotation_rate` and `attitude`. Errors: `unavailable`, `busy`, `motion_failed`, `timeout`.

## Apple Shortcuts

### `shortcuts.run`

Runs a shortcut through the documented `shortcuts://x-callback-url` link, then returns to the app. Times out after 55 seconds.

| Parameter | Type | Notes |
|---|---|---|
| `name` | string, required | Exact name, up to 200 characters |
| `input` | string | Text for the shortcut, up to 4 KiB |

Returns:

| Field | Meaning |
|---|---|
| `started` | Always `true` on success |
| `finished` | `false` if the shortcut was still running after 25 seconds |
| `result` | The shortcut's text output, up to 16 KiB, when it gives one |

Errors: `invalid_name`, `input_too_large`, `busy`, `denied_by_user`, `approval_timeout`, `shortcut_cancelled`, `shortcut_failed`, `shortcuts_unavailable`.

Limits to keep in mind:

- The screen visibly switches to Shortcuts and back.
- Some actions in a shortcut ask for confirmation on screen, and a gadget with nobody present will wait.
- The message Shortcuts gives on failure is not passed on, because it can quote private data.

### `shortcuts.list`

Returns `approved`, the names the user has already allowed. iOS gives apps no way to list other shortcuts.

## Local network

### `lan.discover`

Browses for Bonjour services for about 4 seconds. It never scans ports.

| Parameter | Type | Notes |
|---|---|---|
| `service_type` | string | Browse one type, such as `_hue._tcp`. Default is all declared types |

Returns `count` and `devices`, up to 40, each with `name`, `service_type` and `txt`, plus `host` and `port` when resolved. Errors: `permission_required`, `service_type_not_declared`, `busy`.

iOS requires each type to be declared in `Info.plist`. The current list comes from the SDK's device skills:

`_muse-gadget._tcp`, `_airplay._tcp`, `_display._tcp`, `_elg._tcp`, `_ewelink._tcp`, `_googlecast._tcp`, `_hap._tcp`, `_http._tcp`, `_hue._tcp`, `_ipp._tcp`, `_ipps._tcp`, `_mieleathome._tcp`, `_spotify-connect._tcp`.

### `lan.request`

Sends one HTTP or HTTPS request. Times out after 45 seconds, including the wait for approval.

| Parameter | Type | Notes |
|---|---|---|
| `host` | string, required | Private IPv4 address or `.local` name |
| `port` | integer | Default 80 for http, 443 for https |
| `scheme` | string | `http` or `https`, default `http` |
| `method` | string | `GET`, `HEAD`, `POST`, `PUT`, `PATCH` or `DELETE`, default `GET` |
| `path` | string | Path and query starting with `/`, default `/` |
| `headers` | object | String values, up to 32 |
| `body` | string | Text body, up to 256 KiB |
| `body_base64` | string | Binary body, used if `body` is absent |
| `timeout_ms` | integer | 1000 to 15000, default 8000 |

Returns `status`, `headers` and `truncated`, plus `body` when the response is text or `body_base64` otherwise. Bodies over 128 KiB are cut off with `truncated: true`.

An HTTP error from the device is a successful command with that `status`. Command errors:

| Group | Codes |
|---|---|
| Rejected request | `host_not_local`, `invalid_scheme`, `invalid_port`, `invalid_method`, `invalid_path`, `invalid_headers`, `invalid_body`, `body_too_large` |
| Approval | `denied_by_user`, `approval_timeout`, `busy`, `foreground_required` |
| Connection | `timeout`, `host_not_found`, `connection_failed`, `request_failed` |
| Security | `tls_failed`, `tls_certificate_changed`, `transport_security_blocked` |

Rules this command enforces:

- Only private IPv4 ranges (10/8, 172.16/12, 192.168/16, 169.254/16) and `.local` names are reachable. IPv6 is not supported.
- Grants are per host and port, and the user can withdraw them in Settings.
- Redirects are returned, never followed, so a device cannot point the request somewhere else.
- `Host`, `Connection`, `Content-Length`, `Transfer-Encoding`, `Upgrade` and `Proxy-Authorization` headers are rejected.
- A device's HTTPS certificate is pinned on first use. If it later changes, requests fail with `tls_certificate_changed` until the user withdraws and grants the device again.
- Device logins are left to Muse: it receives the `401` with its headers and answers with its own `Authorization` header.
- WebSocket, MQTT, UDP, raw TCP and SSDP are not available.

## Adding a command

1. Register a `CommandDefinition` in `IOSCommandRegistry.defaultRegistry`. Names follow the SDK's rule, `word.word` in lowercase, and must not start with `system.`, `file.`, `device.` or `link.` (`device.health` is the SDK's own).
2. Parameter types can be `string`, `integer`, `number`, `boolean`, `object` or `array`.
3. Call the completion exactly once. The registry's watchdog handles a command that never answers.
4. Fail closed: check the permission and that the app is visible, and never ask for a permission from a remote call.
5. Add tests, and update this page and [PROTOCOL-STATUS.md](PROTOCOL-STATUS.md).
