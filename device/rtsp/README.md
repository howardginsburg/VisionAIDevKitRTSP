# RTSP server

`vaidk-rtsp.service` runs `rtspd.py`, the camera's RTSP server. It receives the encoded streams from
the [camera program](../camera/README.md) and serves them to Frigate, VLC or any other RTSP client
that signs in with the admin account ([Stream sign-in](#stream-sign-in)).

| URL | Contents |
|---|---|
| `rtsp://<camera-ip>:8900/live` | Main stream: H.264 or H.265 video, plus AAC audio when the microphone is on, and a talk-back channel for clients that ask for it |
| `rtsp://<camera-ip>:8901/live` | Sub stream: H.264 video (unavailable when the sub stream is off) |

| File | What it is |
|---|---|
| [rtspd.py](rtspd.py) | The RTSP server |
| [rtsp.sh](rtsp.sh) | Starts it with the sign-in settings |
| [net.sh](net.sh) | Network settings, applied before the server starts |
| [vaidk-rtsp.service](vaidk-rtsp.service) | systemd unit: runs `net.sh`, then `rtsp.sh`; restarts the server 2 s after it exits |

## How it works

- **Input.** The server listens on the Unix socket `/run/vaidk/media.sock` (root only), where
  `vaidk-camd` sends each encoded frame with its capture time. The message format is in
  [camd/README.md](../../camd/README.md#output-the-media-socket). When the camera program restarts,
  players stay connected and the video carries on at the next keyframe.
- **RTSP.** `OPTIONS`, `DESCRIBE`, `SETUP`, `PLAY`, `PAUSE`, `TEARDOWN`, `GET_PARAMETER` and
  `SET_PARAMETER`, over IPv4. Up to 8 players at a time, across both ports.
- **TCP only.** RTP and RTCP are interleaved in the RTSP connection. A `SETUP` asking for UDP gets
  `461 Unsupported Transport`, and VLC and ffmpeg then retry over TCP; Frigate and go2rtc use TCP
  already. TCP avoids lost packets on Wi-Fi corrupting large keyframes.
- **Session description.** `DESCRIBE` returns the video's SPS and PPS (and VPS for H.265) and the
  audio's AAC configuration, so players don't have to wait for them in the stream. Right after the
  camera starts, it waits up to 6 s for them, then answers `503` if they still haven't arrived. On
  the sub port it answers `503` straight away when the sub stream is off.
- **Packets.** Video: RFC 6184 (H.264) and RFC 7798 (H.265), with fragmentation units for frames
  larger than 1400 bytes. Access unit delimiters and filler data are dropped, and the parameter sets
  are put in front of every keyframe that lacks them. Audio: RFC 3640 `AAC-hbr`, one AAC frame per
  packet.
- **Joining.** A new player gets video from the next keyframe (about one per `KEYFRAME_SECONDS`, 1 s
  by default) and audio from the same moment.
- **Slow players.** A player that falls more than 4 MB behind is disconnected rather than allowed to
  hold the others back.
- **Changes.** When the codec, resolution or audio format changes (for example after new settings
  were saved), players are disconnected so they reconnect and read the new description; Frigate and
  ffmpeg do this by themselves. A player that connected before the audio was available is
  disconnected once it is, for the same reason, and so is a player that asked for the talk-back
  channel when talk-back is turned on or off.

### Talk-back

The main stream carries a talk-back channel: the ONVIF Streaming Specification's backchannel, which
go2rtc (and so Frigate) uses for two-way audio. A client signs in before it can ask for it.

- **Offered on request.** Only a `DESCRIBE` with `Require: www.onvif.org/ver20/backchannel` gets it,
  as a third track, so other players never see it:

  ```text
  m=audio 0 RTP/AVP 0 8
  c=IN IP4 0.0.0.0
  a=rtpmap:0 PCMU/8000
  a=rtpmap:8 PCMA/8000
  a=control:track3
  a=sendonly
  ```

  `sendonly` is from the client's side: it sends, the camera receives. With talk-back off the server
  ignores the `Require` header and answers with the usual two tracks, and go2rtc carries on without
  two-way audio.
- **Receiving.** After `SETUP` of `track3` and `PLAY`, the client sends G.711 RTP packets
  interleaved on that track's channel. The server takes each packet's payload (after any CSRC list,
  header extension and padding) and passes it, with its payload type, to `vaidk-camd`'s talk socket
  as one datagram ([format](../../camd/README.md#talk-back)). Other payload types are ignored.
- **One talker.** Whoever sends first keeps the speaker until they pause for a second; packets from
  anyone else meanwhile are dropped. A stale session that stopped sending never blocks a new one.
- **Which socket.** `vaidk-camd` announces it in its stream description (`talk=/run/vaidk/talk.sock`)
  only when talk-back is on. If `vaidk-camd` is restarting, packets are dropped.
- **go2rtc.** go2rtc asks for the backchannel on every connection, but sets it up only when someone
  starts talking. It then reconnects: `DESCRIBE`, `SETUP` of every track and the backchannel,
  `PLAY`. That's why Frigate's recording stream should use `#backchannel=0` and talk on a separate
  stream ([README](../../README.md#frigate)).

### Timing

- **Video** RTP timestamps come straight from the camera's capture time, at 90 kHz.
- **Audio** timestamps from the camera are wrong after the first frame: they advance 16 times too
  slowly. So audio is timed by its sample count: frame *n* plays at the first frame's capture time
  plus *n* × 1024 samples. Every 3 s the server compares how late the audio arrives against how late
  it arrived at the start. If the two clocks have drifted more than 60 ms apart, it leaves a gap or
  skips whole AAC frames (21.3 ms each) to line the audio up again, and counts a correction.
- **One clock.** The capture clock runs at the hardware clock's rate, which NTP never adjusts. So the
  server and `vaidk-camd` measure arrival times on `CLOCK_MONOTONIC_RAW`, and convert them to the
  capture clock with the offset `vaidk-camd` reports when the camera starts. When chrony slews the
  system clock, as it often does after boot, nothing here moves.
- **RTCP sender reports**, sent right after `PLAY` and then every 2 s, map both streams to the same
  wall clock, which is how players line audio up with video.

## Stream sign-in

With `STREAM_AUTH=1` (the default), both ports need the admin account, by HTTP Digest (RFC 2617), the
sign-in RTSP players know.

- **What needs it:** every request except `OPTIONS`. A connection signs in once; its later requests,
  and talk-back on it, need nothing more.
- **The challenge:** `401 Unauthorized` with `WWW-Authenticate: Digest realm="Vision AI DevKit",
  nonce="..."`, a random nonce for each connection that is good only on it. It offers no `qop`,
  because go2rtc (Frigate's client) and live555 (VLC's) answer without one; an answer with
  `qop=auth`, as FFmpeg gives when offered, is accepted too. MD5 only.
- **No Basic:** a Basic answer would carry the admin password, which also unlocks SSH and `sudo`, in
  clear on every connection. It gets the Digest challenge again, and isn't counted as wrong, because
  some players try Basic first.
- **Old nonces:** the right password with another connection's nonce gets a new challenge with
  `stale=TRUE`, so a player that reuses one signs in on its next try.
- **The camera itself** (127.x) doesn't sign in.

**The key.** The server never sees the password. The setup page writes
`/data/misc/vaidk/stream-key` (root only) when the admin password is set or entered: one line,
`USER HA1 FINGERPRINT`, where `HA1` is MD5(`USER:Vision AI DevKit:password`), the hash Digest needs,
and `FINGERPRINT` is the SHA-256 of the account's password hash in `/etc/shadow`. Before writing it,
the page checks the password against `/etc/shadow` with BusyBox `cryptpw`, which reads it from a
pipe. The server looks at the key, the admin account
(`/data/misc/vaidk/admin`) and `/etc/shadow` every 2 s, so changes take effect without a restart.

**Locked.** The streams refuse every password until the admin password is entered once on the setup
page (Video tab, **Stream sign-in**), or over USB with `ui.sh stream-key`. `rtsp.status` says why:

| `auth_reason` | When |
|---|---|
| `no-key` | No key, or one for another account: after updating from a version without sign-in, or when an existing account became the admin account (`ui.sh adopt-admin`), whose password the add-on never saw |
| `password-changed` | The fingerprint no longer matches: the password was changed outside the setup page, such as with `passwd` over SSH |
| `no-account` | There is no admin account yet (setup mode) |

**When the key changes** (a new password, or the streams lock), every connection signed in with the
old key closes; players reconnect and sign in with the new password.

**Wrong passwords and spare places:**

| Limit | Value |
|---|---|
| Wrong answers on one connection | 3, then it closes once its last reply is sent (5 s at most); anything more it sends is ignored |
| Time to sign in | 15 s, then the connection closes |
| Connections not yet signed in, at once | 4 of the 8 places, so signed-in players keep the rest; 3 from one address, so one host can't take them all. When all 4 are taken, the one waiting longest gives way to a newcomer and counts as a failure, so idle connections can't keep players out |
| Failures from one address: wrong answers, and connections that didn't sign in in time | 10 within a minute; then its new connections are refused for a minute. There is no account lockout, which would itself stop Frigate |
| A request's `Authorization` header and body | Up to 1 KB and 16 KB; a longer answer counts as wrong, and a bad `Content-Length` closes the connection |

**Off.** Add `STREAM_AUTH=0` to `/data/misc/vaidk/vaidk.conf` and run
`systemctl restart vaidk-rtsp`: anyone who can reach the camera can then watch it and use its
speaker. The setup page doesn't offer this.

## Status

`/run/vaidk/rtsp.status`, rewritten every second:

| Field | Meaning |
|---|---|
| `camera` | `1` while `vaidk-camd` is connected |
| `main`, `sub` | Codec of each stream, or `off` |
| `main_age`, `sub_age`, `audio_age` | Seconds since the last frame (`-1`: none yet) |
| `audio` | Audio format, e.g. `AAC 48000 Hz 1 ch`, or `off` |
| `audio_corrections` | How many times the audio was realigned with the video |
| `video_latency_ms` | From capture to the server, for the latest main video frame |
| `audio_latency_ms` | Steady-state delay of the audio behind its capture time |
| `clients` | Players currently connected from the network |
| `main_viewers`, `sub_viewers` | The address of each of those players, once per connection (the setup page's **Players** and **Stream viewers**) |
| `auth` | Stream sign-in: `on`, `off` or `locked` |
| `auth_reason` | Why the streams are locked ([above](#stream-sign-in)); empty otherwise |

`/run/vaidk/streaming` exists while the camera program is connected and every enabled stream (main,
sub, audio) has delivered within the last 5 s. The [status lights](../lights/README.md) and the
[setup page](../web/README.md) use it.

## Network settings (`net.sh`)

- **Send buffers.** Raises the kernel's socket send buffers (`wmem_max` 4 MB, `wmem_default` 1 MB,
  `tcp_wmem` up to 4 MB), so a keyframe burst to a player on slow Wi-Fi fits.
- **Vendor control APIs.** With `LOCK_CONTROL_API=1`, rejects TCP connections to ports 4000 (the
  vendor media server) and 1080 (the vendor preview server) from anywhere but the camera itself, over
  IPv4 (`iptables`) and IPv6 (`ip6tables`): the media server listens on both (`:::4000`). Port 4000
  has no authentication and port 1080 uses `admin`/`admin`; nothing in the add-on uses either. Then
  it checks that each rule is in place; if an IPv6 rule can't be added, it logs a warning and turns
  IPv6 off on the Wi-Fi interfaces instead.
- **Setup network.** Drops packets from `192.168.143.0/24` that arrive over the Wi-Fi client
  (`wlan0`): the setup page trusts that subnet, which must only exist on the camera's own setup
  network.

The settings it reads, `LOCK_CONTROL_API` here and `STREAM_AUTH` in `rtsp.sh`, are in
[defaults.conf](../defaults.conf).

## Logs and checks

```sh
journalctl -u vaidk-rtsp --no-pager -n 30        # camera connections, players, talkers and sign-in
cat /run/vaidk/rtsp.status
ffprobe -rtsp_transport tcp rtsp://<user>:<password>@<camera-ip>:8900/live   # from your PC
```

`talk-back from <address>` in the log marks a new client taking the speaker. Sign-in logs
`stream sign-in: on, as <user>` or `the streams are locked: <why>`; `wrong stream password from
<address>`, `<address> didn't sign in within 15 s` and `<address> gave its place to a newcomer: it
hadn't signed in` at most every 10 s per address; and `too many failed stream sign-ins from
<address>` when it refuses one.

## Why Python, and how

The camera's Python is 3.5.3 with a partial standard library: no `socket` module (its `selectors`
dependency is missing), no `threading`, `json`, `base64` or `signal`. `rtspd.py` uses only what is
there: `_socket`, `select.epoll`, `struct`, `binascii` and `re`, in a single event loop.
