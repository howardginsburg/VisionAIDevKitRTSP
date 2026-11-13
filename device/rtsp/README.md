# RTSP server

`vaidk-rtsp.service` runs `rtspd.py`, the camera's RTSP server. It receives the encoded streams from
the [camera program](../camera/README.md) and serves them to Frigate, VLC or any other RTSP client.

| URL | Contents |
|---|---|
| `rtsp://<camera-ip>:8900/live` | Main stream: H.264 or H.265 video, plus AAC audio when the microphone is on, and a talk-back channel for clients that ask for it |
| `rtsp://<camera-ip>:8901/live` | Sub stream: H.264 video (unavailable when the sub stream is off) |

| File | What it is |
|---|---|
| [rtspd.py](rtspd.py) | The RTSP server |
| [net.sh](net.sh) | Network settings, applied before the server starts |
| [vaidk-rtsp.service](vaidk-rtsp.service) | systemd unit: runs `net.sh`, then the server; restarts it 2 s after it exits |

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
go2rtc (and so Frigate) uses for two-way audio.

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

`/run/vaidk/streaming` exists while the camera program is connected and every enabled stream (main,
sub, audio) has delivered within the last 5 s. The [status lights](../lights/README.md) and the
[setup page](../web/README.md) use it.

## Network settings (`net.sh`)

- **Send buffers.** Raises the kernel's socket send buffers (`wmem_max` 4 MB, `wmem_default` 1 MB,
  `tcp_wmem` up to 4 MB), so a keyframe burst to a player on slow Wi-Fi fits.
- **Vendor control APIs.** With `LOCK_CONTROL_API=1`, rejects TCP connections to ports 4000 (the
  vendor media server) and 1080 (the vendor preview server) from anywhere but the camera itself.
  Port 4000 has no authentication and port 1080 uses `admin`/`admin`; nothing in the add-on uses either.
- **Setup network.** Drops packets from `192.168.143.0/24` that arrive over the Wi-Fi client
  (`wlan0`): the setup page trusts that subnet, which must only exist on the camera's own setup
  network.

The settings it reads, `LOCK_CONTROL_API`, are in [defaults.conf](../defaults.conf).

## Logs and checks

```sh
journalctl -u vaidk-rtsp --no-pager -n 30        # camera connections, players and talkers
cat /run/vaidk/rtsp.status
ffprobe -rtsp_transport tcp rtsp://<camera-ip>:8900/live   # from your PC
```

`talk-back from <address>` in the log marks a new client taking the speaker.

## Why Python, and how

The camera's Python is 3.5.3 with a partial standard library: no `socket` module (its `selectors`
dependency is missing), no `threading`, `json`, `base64` or `signal`. `rtspd.py` uses only what is
there: `_socket`, `select.epoll`, `struct`, `binascii` and `re`, in a single event loop.
