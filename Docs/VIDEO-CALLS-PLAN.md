# Video calls with Muse: findings and porting plan

Status: research, 2026-11-11. Nothing here is built yet.

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
