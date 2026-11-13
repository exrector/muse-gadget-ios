# Video calls with Muse: findings and porting plan

Status: built and in the 2.0 beta, 2026-11-12. All five steps of the plan below are done and checked on an iPad (6th generation) and an iPhone 6s; the measurements are under [Results](#results). The research notes are kept as written, so the sections before Results describe the starting point.

## Why

In a voice call Pal Again shows Muse's avatar as a looping `call_speaking` clip. It cannot follow
the real speech. Meta's own Muse app shows the avatar talking in sync, which is a video call:
Muse renders its avatar and streams it.

## What the server does

- A realtime voice call (`POST /voice/realtime`, `call_media_type: "audio"`) is what Pal Again
  uses now. Its `continuous_audio_video.delta` events carry a `video_delta` field that the SDK
  ignores.
- Opened with `call_media_type: "video"`, the same stream sent `video_delta` objects with
  `frame_width`, `frame_height`, `frame_count`, `pixel_format` (a 6-character string) and
  `video_frames` (base64 of about 516 KB raw per delta), about 0.8 deltas a second, 24 MB in 45 s.
  In that mode the server stopped hearing the microphone: no `speech_started` at all. This is not
  the supported path.
- The supported path is Meta's own work in progress: branch `anantn/linux-video-calls` of
  `facebookincubator/muse-gadget-sdk`, commit `77c7e27` ("linux: video calls", 2026-11-10, not in
  `main`). Pal Again's submodule can read it with `git show 77c7e27:linux/...`.

## The protocol in that branch

Signaling goes over the gadget's existing Noise session (the one with `app_id=hatch-web`):

1. `GET /voice/calls/media-endpoint` returns `host`, `port` and `vip_type` (`META_AI` = 2,
   `HATCH` = 8 in the JOIN).
2. `POST /voice/calls/join` with a JSON body that carries a Thrift Compact JOIN
   (`linux/src/musegadget/rtc/join.py`, `build_join`). The client mints everything:
   - ICE: client ufrag (4 chars) and password (24), server ufrag (16) and password (24).
   - SRTP master key: 30 random bytes, base64 in the JOIN. There is no DTLS.
   - DTLS identities for both ends, P-256 self-signed X.509 with a SHA-256 fingerprint. They are
     required fields but unused. iOS has no certificate builder: either a small DER encoder signed
     with CryptoKit P-256, or check whether the server accepts any well-formed certificate.
   - Tracks: audio `AUDIO_TRACK_ASSISTANT` = 1, video `VIDEO_TRACK_ASSISTANT` = 2 (or
     `VIDEO_TRACK_NONE` = 8), `DTLS_ACTIVE` = 1, the endpoint as `host:port`, and session
     parameters with the chat thread ID.
   The answer (`parse_join_response`) gives the server ufrag and the endpoint's IPv4 and IPv6.
   Status in the header must be 200.
3. Media goes straight to the endpoint (`rtc/media.py`, `rtc/stun.py`, `rtc/srtp.py`,
   `rtc/rtp.py`):
   - ICE-lite connectivity check: STUN binding over UDP and RFC 4571 framed TCP on the same port at
     once; the first to answer carries the call. Repeated as consent; 30 s without answers ends it.
   - SRTP (AES-CM 128 with HMAC-SHA1-80, keyed from the JOIN's master key), replay window, only
     the endpoint's SSRCs accepted.
   - Audio: Opus both ways, 48 kHz on the wire (`rtc/opus.py` uses the system libopus).
   - Video: H.264 from Muse at about 1 Mbit/s, RTP depacketized (FU-A, STAP-A). Drops resume at a
     keyframe, asked for with a PLI. Video never blocks or ends the call.
4. `POST /voice/end-call` on every path, as for voice calls.

Half duplex as in voice calls: while Muse speaks and about 0.5 s after, the microphone sends
silence. The call ends after 10 s without media or 30 s without connectivity answers.

## Porting to iOS

| Piece | iOS |
|---|---|
| Signaling | `MuseRuntime.postJSON` and a GET over the Noise session |
| Thrift Compact writer and reader | small Swift port of `_Writer` and `_Reader` |
| Certificates | DER encoder + CryptoKit P-256, or a fixed well-formed certificate if accepted |
| STUN over UDP and TCP | Network.framework `NWConnection` |
| SRTP | CommonCrypto AES-CTR + CryptoKit `HMAC<Insecure.SHA1>` |
| Opus | check AudioToolbox Opus encoding on iOS 15 first; otherwise vendor libopus (BSD) |
| H.264 | RTP depacketizer, then `AVSampleBufferDisplayLayer`, which decodes in hardware on an iPhone 6s |

Steps, each checked on the iPad and the iPhone 6s before the next:

1. Signaling probe: media endpoint and JOIN, logging status codes and the answer's shape. This
   shows whether the server admits a paired gadget to video calls.
2. Connectivity: STUN over UDP and TCP. In Russia this is also the DPI check.
3. Audio over SRTP with Opus: a call that only talks, on the new path.
4. Video: Muse's avatar in the call window, replacing the looping clip.
5. A separate "Video call (beta)" setting; the voice call stays as it is.

The branch is unmerged and may change; compare with it again before each step.

## Results

### Steps 1 and 2, 2026-11-12, iPad (6th generation), iPadOS 17.7.11

DEBUG probe `MuseVideoProbe` (`PAL_V2_VIDEO_PROBE=1`, `PAL_NOISE_APP_ID=hatch-web`):

- `GET /voice/calls/media-endpoint`: HTTP 200, `host` `meta-ai-realtime.facebook.com`, `port`
  3478, `vip_type` `META_AI`. The result also has `ip4_address`, `ip6_address`, `route` and
  `enable_media_to_cosmos`, which the SDK does not read.
- `POST /voice/calls/join` with a 1,009-byte JOIN: HTTP 200, result keys `call` and
  `payload_b64`; the Thrift answer has status 200 and a 19-character server ufrag, no addresses.
- ICE-lite STUN check to the host on port 3478: the first authenticated answer came over UDP in
  237 ms and over RFC 4571 TCP in about 3 s. Both get through the owner's network in Russia.
- `POST /voice/end-call`: HTTP 200.

So Muse admits a paired gadget to a video call, and the media endpoint is reachable.

### Step 3, next: audio over SRTP

From `rtc/srtp.py`, `rtc/opus.py`, `rtc/rtp.py` and `rtc/media.py`:

- SRTP and SRTCP with AES_CM_128_HMAC_SHA1_80 (RFC 3711), keyed directly from the JOIN's 30-byte
  master key and salt (labels 0-2 for RTP, 3-5 for RTCP), rollover counters per SSRC and a replay
  window.
- RTP: Opus payload type 111 at 48 kHz, 20 ms (960 samples) per packet, client audio SSRC 100;
  Muse's audio SSRC 200 and video SSRC 201 (H.264, payload type 127). Only those SSRCs are
  accepted.
- Opus: mono, 48 kHz, application VoIP, 32 kbit/s. First check whether AudioToolbox
  (`kAudioFormatOpus`) encodes and decodes on iOS 15; otherwise vendor libopus.
- Consent: a STUN check every 4 s on the chosen path; 30 s without answers ends the call. A PLI
  asks for a keyframe once connected.

### Step 3, 2026-11-12, iPad (6th generation), iPadOS 17.7.11

A 90-second call over the media path (`PAL_CALL_TRANSPORT=media`): UDP to the media endpoint,
11.2 MB received (about 1 Mbit/s), 1,942 Opus packets and 10,734 H.264 packets from Muse, 513
RTCP, no SRTP or decode errors, 4,128 Opus packets sent. Muse heard the person and answered by
voice. Opus comes from AudioToolbox; libopus was not needed on iPadOS 17 (iOS 15 not yet tried).
Muse already streams its avatar as H.264: step 4 shows it.

### Steps 4 and 5, 2026-11-12, iPad (6th generation), iPadOS 17.7.11

Muse's H.264 is reassembled from RTP (single NAL, STAP-A, FU-A; a loss drops the unit until the
next keyframe, asked for with a PLI) and shown by an `AVSampleBufferDisplayLayer`, which decodes
in hardware. The window takes the picture's proportions from its parameter sets. The owner saw
Muse's face talking in sync, as in the Muse app. "Video Calls with Muse's Avatar (Beta)" (on by
default, under "Live Voice Calls with Muse") chooses the video call; off keeps the realtime
voice call. A video call has no captions: like the SDK's video_call.py it carries only media.
The conversation still lands in the main chat, which refreshes when the call closes.

### The first sentence, 2026-11-12

Muse dropped a call's first sentences (`hatch.voice.input_suppressed` in the realtime call; the
same loss, without events, in the video call) for the first 10-35 s, as reported in
facebookincubator/muse-gadget-sdk#344. Muse's own app did not lose them. The cause was the
`device: "mcu-wearable"` hint the SDK sends: without it, on the iPad, a voice call accepted the
first and a 15-second second sentence with no suppression at all, and a video call was admitted
and answered the first sentence. Calls now leave the hint out; voice notes keep it only with
"Short Replies to Voice". A "Muse Greets First" setting (on by default) sets
`proactive_greeting_enabled` for both kinds of call.

### iPhone 6s and layouts, 2026-11-12

On the iPhone 6s with iOS 15.8.8 a video call ran over UDP, connected in 2.7 s and showed 852 of
853 assembled frames with no SRTP or decode errors. AudioToolbox encodes Opus on iOS 15 too, so
libopus is not needed. Muse's video is 448x768 at about 18 frames a second; on an iPad it is
scaled up about 1.7-2x whatever the app does, and nothing in the JOIN asks for more.

Every layout crops the empty white above and below the avatar to the middle 60% of the height. A
phone held sideways shows the picture with one status line under it and the buttons in a column
on the right. An iPad switches its microphones when it turns, which changes the audio
configuration; the call then reconnects the player and mixer before restarting the engine, or
Muse played into nothing after a turn.
