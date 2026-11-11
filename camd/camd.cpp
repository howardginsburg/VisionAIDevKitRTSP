// vaidk-camd: runs the Vision AI DevKit camera through Qualcomm's qmmf-server and streams the
// encoded video and microphone audio to the add-on's RTSP server (rtspd.py) over a Unix socket.
//
//   stream 1  main video  (H.264 or H.265)
//   stream 2  sub video   (H.264, optional)
//   stream 3  microphone  (AAC-LC raw access units, optional)
//
// In the other direction it plays talk-back audio from the RTSP server's backchannel on the speaker
// (talkback.cpp). Settings come from environment variables (see device/camera/camd.sh); the ones
// that can change while streaming are re-read from CAMD_LIVE on SIGHUP, and SIGUSR1 plays a test
// chime. Each message on the socket is a 28-byte little-endian Header followed by the payload;
// stream 0 carries "key=value" lines describing the streams and is sent first on every connection.
// camd exits when the camera pipeline fails or stops delivering frames; systemd then starts it with
// a fresh session.
// The qmmf headers use memcpy/memset without including <cstring> themselves.
#include <cstring>

#include <qmmf-sdk/qmmf_recorder.h>

#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "common.h"
#include "image.h"
#include "talkback.h"

using namespace qmmf;
using namespace qmmf::recorder;

namespace {

const uint32_t kMagic = 0x4b494156;  // "VAIK"
enum : uint8_t { kInfo = 0, kMain = 1, kSub = 2, kAudio = 3, kStreams = 4 };
enum : uint8_t { kKeyframe = 1, kCodecConfig = 2 };
const uint32_t kCameraId = 0;
const uint32_t kTrackIds[kStreams] = {0, 1, 2, 101};
const char *const kNames[kStreams] = {"info", "main", "sub", "audio"};
const size_t kQueueLimit = 16u << 20;  // drop frames when the RTSP server falls this far behind
const uint64_t kStallUs = 10000000;    // restart when an enabled stream stops for this long

#pragma pack(push, 1)
struct Header {
  uint32_t magic;
  uint8_t stream;
  uint8_t flags;
  uint16_t reserved;
  uint64_t timestamp;  // capture timestamp from the camera pipeline, as reported by qmmf
  uint64_t received;   // CLOCK_MONOTONIC_RAW (microseconds) when camd received the buffer
  uint32_t length;
};
#pragma pack(pop)
static_assert(sizeof(Header) == 28, "Header must stay 28 bytes");

std::atomic<bool> g_stop(false);
std::atomic<bool> g_failed(false);
std::atomic<bool> g_reload(false);
std::atomic<bool> g_chime(false);

struct VideoConfig {
  bool enabled;
  bool hevc;
  uint32_t width, height, fps, bitrate;
};

struct Config {
  VideoConfig video[kStreams];
  bool audio;
  uint32_t audio_rate, audio_channels, audio_bitrate;
  uint32_t camera_fps, keyframe_seconds, debug;
  bool overlay_time, overlay_name, overlay_sub;
  overlay::OverlayLocationType time_corner, name_corner;
  std::string name, socket_path, talk_path, on_start, live_path, raw_metadata;
  bool dump_metadata;
};

overlay::OverlayLocationType corner(const std::string &value) {
  if (value == "top-right") return overlay::OverlayLocationType::kTopRight;
  if (value == "bottom-left") return overlay::OverlayLocationType::kBottomLeft;
  if (value == "bottom-right") return overlay::OverlayLocationType::kBottomRight;
  return overlay::OverlayLocationType::kTopLeft;
}

// The same side, the other edge: the name goes under (or over) the date and time.
overlay::OverlayLocationType opposite_edge(overlay::OverlayLocationType c) {
  switch (c) {
    case overlay::OverlayLocationType::kTopLeft: return overlay::OverlayLocationType::kBottomLeft;
    case overlay::OverlayLocationType::kTopRight: return overlay::OverlayLocationType::kBottomRight;
    case overlay::OverlayLocationType::kBottomLeft: return overlay::OverlayLocationType::kTopLeft;
    default: return overlay::OverlayLocationType::kTopRight;
  }
}

Config load_config() {
  Config c{};
  c.video[kMain] = {true, env_u32("MAIN_CODEC", 1) == 0, env_u32("MAIN_WIDTH", 1920),
                    env_u32("MAIN_HEIGHT", 1080), env_u32("MAIN_FPS", 30), env_u32("MAIN_BITRATE", 4000000)};
  c.video[kSub] = {env_u32("SUB_ENABLED", 1) == 1, false, env_u32("SUB_WIDTH", 640),
                   env_u32("SUB_HEIGHT", 360), env_u32("SUB_FPS", 5), env_u32("SUB_BITRATE", 500000)};
  c.audio = env_u32("AUDIO_ENABLED", 1) == 1;
  c.audio_rate = env_u32("AUDIO_RATE", 48000);
  c.audio_channels = env_u32("AUDIO_CHANNELS", 1);
  c.audio_bitrate = env_u32("AUDIO_BITRATE", 64000);
  c.camera_fps = env_u32("CAMERA_FPS", 30);
  c.keyframe_seconds = env_u32("KEYFRAME_SECONDS", 1);
  c.debug = env_u32("CAMD_DEBUG", 0);
  std::string overlay = env_str("OVERLAY", "off");
  c.overlay_time = overlay == "time" || overlay == "time-name";
  c.overlay_name = overlay == "name" || overlay == "time-name";
  c.overlay_sub = env_str("OVERLAY_STREAMS", "main") == "both";
  c.time_corner = corner(env_str("OVERLAY_POSITION", "top-left"));
  c.name_corner = c.overlay_time ? opposite_edge(c.time_corner) : c.time_corner;
  c.name = env_str("NAME", "");
  c.socket_path = env_str("CAMD_SOCKET", "/run/vaidk/media.sock");
  c.talk_path = env_str("CAMD_TALK", "");
  c.on_start = env_str("CAMD_ON_START", "");
  c.live_path = env_str("CAMD_LIVE", "/run/vaidk/camd.conf");
  c.raw_metadata = env_str("CAMD_SET", "");
  c.dump_metadata = env_u32("CAMD_METADATA", 0) == 1;
  return c;
}

// Sends messages to the RTSP server from its own thread so qmmf callbacks never block.
class Output {
 public:
  explicit Output(const std::string &path) : path_(path) {}

  void start(const std::string &info) {
    info_ = info;
    thread_ = std::thread([this] { run(); });
  }

  void stop() {
    {
      std::lock_guard<std::mutex> lock(lock_);
      stopping_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
  }

  void push(uint8_t stream, uint8_t flags, uint64_t timestamp, uint64_t received, const void *data,
            uint32_t size) {
    std::lock_guard<std::mutex> lock(lock_);
    if (flags & kCodecConfig) config_[stream] = message(stream, flags, timestamp, received, data, size);
    bool video = stream == kMain || stream == kSub;
    if (fd_ < 0) {
      need_key_[stream] = video;
      return;
    }
    if (video && need_key_[stream]) {
      if (!(flags & (kKeyframe | kCodecConfig))) {
        ++dropped_;
        return;
      }
      if (flags & kKeyframe) need_key_[stream] = false;
    }
    if (queued_ + size > kQueueLimit) {
      need_key_[stream] = video;
      ++dropped_;
      return;
    }
    queue_.push_back(message(stream, flags, timestamp, received, data, size));
    queued_ += queue_.back().size();
    cv_.notify_one();
  }

  uint64_t dropped() {
    std::lock_guard<std::mutex> lock(lock_);
    return dropped_;
  }

 private:
  static std::vector<uint8_t> message(uint8_t stream, uint8_t flags, uint64_t timestamp, uint64_t received,
                                      const void *data, uint32_t size) {
    Header h{kMagic, stream, flags, 0, timestamp, received, size};
    std::vector<uint8_t> m(sizeof(h) + size);
    memcpy(m.data(), &h, sizeof(h));
    if (size) memcpy(m.data() + sizeof(h), data, size);
    return m;
  }

  static bool send_all(int fd, const std::vector<uint8_t> &m) {
    size_t sent = 0;
    while (sent < m.size()) {
      ssize_t n = send(fd, m.data() + sent, m.size() - sent, MSG_NOSIGNAL);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return false;
      sent += size_t(n);
    }
    return true;
  }

  int connect_socket() {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path_.c_str(), sizeof(addr.sun_path) - 1);
    int buffer = 2 << 20;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer));
    if (connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
      close(fd);
      return -1;
    }
    return fd;
  }

  void disconnect() {  // lock_ held
    if (fd_ >= 0) close(fd_);
    fd_ = -1;
    queue_.clear();
    queued_ = 0;
  }

  void run() {
    std::unique_lock<std::mutex> lock(lock_);
    bool announced_wait = false;
    while (!stopping_) {
      if (fd_ < 0) {
        lock.unlock();
        int fd = connect_socket();
        lock.lock();
        if (fd < 0) {
          if (!announced_wait) note("waiting for the RTSP server at %s", path_.c_str());
          announced_wait = true;
          cv_.wait_for(lock, std::chrono::seconds(1), [this] { return stopping_; });
          continue;
        }
        std::vector<std::vector<uint8_t>> hello;
        hello.push_back(message(kInfo, 0, 0, now_us(), info_.data(), uint32_t(info_.size())));
        for (auto &c : config_)
          if (!c.empty()) hello.push_back(c);
        lock.unlock();
        bool ok = true;
        for (auto &m : hello) ok = ok && send_all(fd, m);
        lock.lock();
        if (!ok) {
          close(fd);
          continue;
        }
        fd_ = fd;
        for (auto &n : need_key_) n = true;
        need_key_[kAudio] = false;
        announced_wait = false;
        note("connected to the RTSP server");
        continue;
      }
      if (queue_.empty()) {
        cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
        continue;
      }
      std::vector<uint8_t> m = std::move(queue_.front());
      queue_.pop_front();
      queued_ -= m.size();
      int fd = fd_;
      lock.unlock();
      bool ok = send_all(fd, m);
      lock.lock();
      if (!ok) {
        note("RTSP server connection lost");
        disconnect();
      }
    }
    disconnect();
  }

  std::string path_, info_;
  std::thread thread_;
  std::mutex lock_;
  std::condition_variable cv_;
  std::deque<std::vector<uint8_t>> queue_;
  std::vector<uint8_t> config_[kStreams];
  bool need_key_[kStreams] = {false, true, true, false};
  size_t queued_ = 0;
  uint64_t dropped_ = 0;
  int fd_ = -1;
  bool stopping_ = false;
};

class Camera {
 public:
  Camera(const Config &cfg, Output &out) : cfg_(cfg), out_(out) {}

  bool start() {
    RecorderCb recorder_cb;
    recorder_cb.event_cb = [](EventType type, void *, size_t) {
      note("camera service event %d (%s)", int(type), type == EventType::kServerDied ? "server died" : "camera error");
      g_failed = true;
    };
    status_t ret = recorder_.Connect(recorder_cb);
    if (ret != 0) return failed("connect to qmmf-server", ret);
    connected_ = true;

    CameraStartParam camera;
    camera.zsl_mode = false;
    camera.zsl_queue_depth = 8;
    camera.zsl_width = 1920;
    camera.zsl_height = 1080;
    camera.frame_rate = cfg_.camera_fps;
    camera.flags = 0;
    ret = recorder_.StartCamera(kCameraId, camera);
    if (ret != 0) return failed("start the camera", ret);
    camera_started_ = true;

    // All tracks must exist before any session starts: adding a track to a running camera
    // starves the encoder of the tracks already running on this firmware.
    uint32_t main_session = 0;
    if (!create_session(&main_session) || !create_video(main_session, kMain)) return false;
    if (cfg_.audio && !create_audio(main_session)) note("microphone unavailable; streaming without audio");
    if (cfg_.video[kSub].enabled) {
      uint32_t sub_session = 0;
      if (!create_session(&sub_session) || !create_video(sub_session, kSub)) return false;
    }
    for (uint32_t session : sessions_) {
      ret = recorder_.StartSession(session);
      if (ret != 0) return failed("start a session", ret);
      started_.push_back(session);
    }
    started_us_ = now_us();
    clock_offset_us_ = int64_t(clock_us(CLOCK_MONOTONIC)) - int64_t(started_us_);

    image_.init();
    if (cfg_.dump_metadata) image_.dump(recorder_, kCameraId);
    add_overlays();
    return true;
  }

  // Applies the image settings, which can change while streaming (CAMD_SET adds raw tags).
  void apply_image(std::map<std::string, std::string> settings) {
    if (!cfg_.raw_metadata.empty()) settings["RAW"] = cfg_.raw_metadata;
    note("image: %s", image_.apply(recorder_, kCameraId, settings).c_str());
  }

  void stop() {
    for (auto &o : overlays_) {
      recorder_.RemoveOverlay(o.first, o.second);
      recorder_.DeleteOverlayObject(o.first, o.second);
    }
    overlays_.clear();
    for (uint32_t session : started_) recorder_.StopSession(session, false);
    started_.clear();
    for (auto &t : audio_tracks_) recorder_.DeleteAudioTrack(t.first, t.second);
    for (auto &t : video_tracks_) recorder_.DeleteVideoTrack(t.first, t.second);
    audio_tracks_.clear();
    video_tracks_.clear();
    for (uint32_t session : sessions_) recorder_.DeleteSession(session);
    sessions_.clear();
    if (camera_started_) recorder_.StopCamera(kCameraId);
    camera_started_ = false;
    if (connected_) recorder_.Disconnect();
    connected_ = false;
  }

  // Returns the name of an enabled stream that stopped delivering, or nullptr.
  const char *stalled() {
    std::lock_guard<std::mutex> lock(stats_lock_);
    uint64_t now = now_us();
    for (uint8_t s = kMain; s < kStreams; ++s) {
      if (!active_[s]) continue;
      uint64_t last = last_us_[s] ? last_us_[s] : started_us_;
      if (now - last > kStallUs) return kNames[s];
    }
    return nullptr;
  }

  // "key=value" lines describing the streams that are running (sent to the RTSP server).
  std::string describe() {
    char text[512];
    int len = 0;
    for (uint8_t s = kMain; s <= kSub; ++s) {
      const VideoConfig &v = cfg_.video[s];
      if (active_[s])
        len += snprintf(text + len, sizeof(text) - len, "%s=%s %ux%u %u %u\n", kNames[s], v.hevc ? "H265" : "H264",
                        v.width, v.height, v.fps, v.bitrate);
    }
    if (active_[kAudio])
      len += snprintf(text + len, sizeof(text) - len, "audio=AAC %u %u %u\n", cfg_.audio_rate, cfg_.audio_channels,
                      cfg_.audio_bitrate);
    // The capture clock minus the arrival clock, in microseconds.
    len += snprintf(text + len, sizeof(text) - len, "clock=%lld\n", static_cast<long long>(clock_offset_us_));
    return std::string(text, size_t(len));
  }

  std::string stats() {
    std::lock_guard<std::mutex> lock(stats_lock_);
    char line[256];
    int len = 0;
    for (uint8_t s = kMain; s < kStreams; ++s) {
      if (!active_[s]) continue;
      len += snprintf(line + len, sizeof(line) - len, "%s%s %llu frames %llu KB", len ? ", " : "", kNames[s],
                      static_cast<unsigned long long>(frames_[s]), static_cast<unsigned long long>(bytes_[s] >> 10));
    }
    return std::string(line, len > 0 ? size_t(len) : 0);
  }

 private:
  bool failed(const char *what, status_t ret) {
    note("failed to %s (%d)", what, int(ret));
    return false;
  }

  bool create_session(uint32_t *session) {
    SessionCb cb;
    cb.event_cb = [](EventType, void *, size_t) {};
    status_t ret = recorder_.CreateSession(cb, session);
    if (ret != 0) return failed("create a session", ret);
    sessions_.push_back(*session);
    return true;
  }

  TrackCb track_cb(uint8_t stream, uint32_t session) {
    TrackCb cb;
    cb.data_cb = [this, stream, session](uint32_t track, std::vector<BufferDescriptor> buffers,
                                         std::vector<MetaData>) { on_data(stream, session, track, buffers); };
    cb.event_cb = [stream](uint32_t, EventType type, void *, size_t) {
      note("%s track event %d", kNames[stream], int(type));
      g_failed = true;
    };
    return cb;
  }

  bool create_video(uint32_t session, uint8_t stream) {
    const VideoConfig &v = cfg_.video[stream];
    VideoTrackCreateParam p(kCameraId, v.hevc ? VideoFormat::kHEVC : VideoFormat::kAVC, v.width, v.height,
                            float(v.fps));
    if (v.hevc) {
      p.codec_param.hevc.bitrate = v.bitrate;
      p.codec_param.hevc.idr_interval = cfg_.keyframe_seconds;
      p.codec_param.hevc.prepend_sps_pps_to_idr = true;
      p.codec_param.hevc.insert_aud_delimiter = false;
    } else {
      p.codec_param.avc.bitrate = v.bitrate;
      p.codec_param.avc.idr_interval = cfg_.keyframe_seconds;
      p.codec_param.avc.prepend_sps_pps_to_idr = true;
      p.codec_param.avc.insert_aud_delimiter = false;
    }
    status_t ret = recorder_.CreateVideoTrack(session, kTrackIds[stream], p, track_cb(stream, session));
    if (ret != 0) {
      note("%s stream %ux%u@%u %s rejected (%d)", kNames[stream], v.width, v.height, v.fps, v.hevc ? "H.265" : "H.264",
          int(ret));
      return false;
    }
    video_tracks_.push_back({session, kTrackIds[stream]});
    active_[stream] = true;
    return true;
  }

  // The date and time (drawn by qmmf-server in its own time zone) and the camera name, burned into the
  // video. qmmf draws thin white text and scales it to a box: 12% x 12% of the frame for the date and
  // time, 30% x 10% for the name. A translucent dark label behind each keeps it readable on any scene.
  void add_overlays() {
    for (uint8_t s = kMain; s <= kSub; ++s) {
      if (!active_[s] || (s == kSub && !cfg_.overlay_sub)) continue;
      int32_t width = int32_t(cfg_.video[s].width), height = int32_t(cfg_.video[s].height);
      if (cfg_.overlay_time) {
        overlay::OverlayParam p;
        memset(&p, 0, sizeof(p));
        p.type = overlay::OverlayType::kDateType;
        p.date_time.time_format = overlay::OverlayTimeFormatType::kHHMMSS_24HR;
        p.date_time.date_format = overlay::OverlayDateFormatType::kYYYYMMDD;
        int32_t box_w = width * 12 / 100, box_h = height * 12 / 100;
        // The two lines fill the middle of qmmf's box: from 22% to 80% of its height.
        add_labelled(s, p, cfg_.time_corner, width, height, box_w, box_h, box_h * 22 / 100, box_h * 58 / 100);
      }
      if (cfg_.overlay_name && !cfg_.name.empty()) {
        overlay::OverlayParam p;
        memset(&p, 0, sizeof(p));
        p.type = overlay::OverlayType::kUserText;
        strncpy(p.user_text, cfg_.name.c_str(), MAX_STRING_LENGTH - 1);
        int32_t box_w = width * 30 / 100, box_h = height * 10 / 100;
        // Left-aligned in the top half of its box, about 1.05% of the frame width per character.
        int32_t text_w = int32_t(cfg_.name.size()) * width * 105 / 10000 + width / 100;
        add_labelled(s, p, cfg_.name_corner, width, height, text_w < box_w ? text_w : box_w, box_h, 0, box_h * 55 / 100);
      }
    }
  }

  // Places an item in a corner, with qmmf's own 0.5% margins, on a label of label_w x label_h at
  // label_y inside the item's box. On the right, the item moves so its (left-aligned) text ends at the
  // margin.
  void add_labelled(uint8_t stream, overlay::OverlayParam p, overlay::OverlayLocationType where, int32_t width,
                    int32_t height, int32_t label_w, int32_t box_h, int32_t label_y, int32_t label_h) {
    int32_t mx = width / 200, my = height / 200;
    bool right = where == overlay::OverlayLocationType::kTopRight || where == overlay::OverlayLocationType::kBottomRight;
    bool bottom = where == overlay::OverlayLocationType::kBottomLeft || where == overlay::OverlayLocationType::kBottomRight;
    int32_t x = right ? width - label_w - mx : mx;
    int32_t y = bottom ? height - box_h - my : my;
    if (bottom && label_y + label_h < box_h) y += box_h - (label_y + label_h);  // no gap under a bottom label
    overlay::OverlayParam label;
    memset(&label, 0, sizeof(label));
    label.type = overlay::OverlayType::kPrivacyMask;
    label.location = overlay::OverlayLocationType::kRandom;
    label.color = 0x00000090;  // RGBA: black, 56% opaque
    label.dst_rect.start_x = x;
    label.dst_rect.start_y = y + label_y;
    label.dst_rect.width = label_w;
    label.dst_rect.height = label_h;
    add_overlay(stream, label);
    p.location = overlay::OverlayLocationType::kRandom;
    p.color = 0xFFFFFFFF;
    p.dst_rect.start_x = x;
    p.dst_rect.start_y = y;
    // A zero size keeps qmmf's own drawing surface, which it scales to the box; only the position is ours.
    p.dst_rect.width = 0;
    p.dst_rect.height = 0;
    add_overlay(stream, p);
  }

  void add_overlay(uint8_t stream, overlay::OverlayParam &p) {
    uint32_t id = 0;
    status_t ret = recorder_.CreateOverlayObject(kTrackIds[stream], p, &id);
    if (ret == 0) ret = recorder_.SetOverlay(kTrackIds[stream], id);
    if (ret != 0) {
      note("%s overlay %d failed (%d)", kNames[stream], int(p.type), int(ret));
      return;
    }
    overlays_.push_back({kTrackIds[stream], id});
  }

  bool create_audio(uint32_t session) {
    AudioTrackCreateParam p;
    memset(&p, 0, sizeof(p));
    p.in_devices_num = 1;
    p.in_devices[0] = static_cast<DeviceId>(AudioDeviceId::kBuiltIn);
    p.sample_rate = cfg_.audio_rate;
    p.channels = cfg_.audio_channels;
    p.bit_depth = 16;
    p.format = AudioFormat::kAAC;
    p.codec_params.aac.format = AACFormat::kMP4FF;
    p.codec_params.aac.mode = AACMode::kAALC;
    p.codec_params.aac.bit_rate = int32_t(cfg_.audio_bitrate);
    status_t ret = recorder_.CreateAudioTrack(session, kTrackIds[kAudio], p, track_cb(kAudio, session));
    if (ret != 0) return failed("create the microphone track", ret);
    audio_tracks_.push_back({session, kTrackIds[kAudio]});
    active_[kAudio] = true;
    return true;
  }

  void on_data(uint8_t stream, uint32_t session, uint32_t track, std::vector<BufferDescriptor> &buffers) {
    uint64_t received = now_us();
    for (const BufferDescriptor &b : buffers) {
      uint8_t flags = 0;
      if (b.flag & static_cast<uint32_t>(BufferFlags::kFlagIDRFrame)) flags |= kKeyframe;
      if (b.flag & static_cast<uint32_t>(BufferFlags::kFlagCodecConfig)) flags |= kCodecConfig;
      if (b.data && b.size) out_.push(stream, flags, b.timestamp, received, b.data, b.size);
      std::lock_guard<std::mutex> lock(stats_lock_);
      ++frames_[stream];
      bytes_[stream] += b.size;
      last_us_[stream] = received;
      if (debug_left_[stream] < cfg_.debug) {
        ++debug_left_[stream];
        note("debug %s: size %u offset %u flag 0x%x ts %llu | raw %llu mono %llu real %llu", kNames[stream], b.size,
            b.offset, b.flag, static_cast<unsigned long long>(b.timestamp),
            static_cast<unsigned long long>(received), static_cast<unsigned long long>(clock_us(CLOCK_MONOTONIC)),
            static_cast<unsigned long long>(clock_us(CLOCK_REALTIME)));
      }
    }
    recorder_.ReturnTrackBuffer(session, track, buffers);
  }

  const Config &cfg_;
  Output &out_;
  Recorder recorder_;
  ImageControl image_;
  bool connected_ = false, camera_started_ = false;
  std::vector<uint32_t> sessions_, started_;
  std::vector<std::pair<uint32_t, uint32_t>> video_tracks_, audio_tracks_, overlays_;
  std::mutex stats_lock_;
  bool active_[kStreams] = {false, false, false, false};
  uint64_t frames_[kStreams] = {0, 0, 0, 0}, bytes_[kStreams] = {0, 0, 0, 0}, last_us_[kStreams] = {0, 0, 0, 0};
  uint32_t debug_left_[kStreams] = {0, 0, 0, 0};
  uint64_t started_us_ = 0;
  int64_t clock_offset_us_ = 0;
};

}  // namespace

int main() {
  setvbuf(stdout, nullptr, _IOLBF, 0);
  signal(SIGPIPE, SIG_IGN);
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = [](int) { g_stop = true; };
  sigaction(SIGTERM, &sa, nullptr);
  sigaction(SIGINT, &sa, nullptr);
  sa.sa_handler = [](int) { g_reload = true; };
  sigaction(SIGHUP, &sa, nullptr);
  sa.sa_handler = [](int) { g_chime = true; };
  sigaction(SIGUSR1, &sa, nullptr);

  Config cfg = load_config();
  Output out(cfg.socket_path);
  Camera camera(cfg, out);
  Talkback talk;
  // The settings that can change while streaming: image controls and the speaker.
  auto apply_live = [&cfg, &camera, &talk] {
    std::map<std::string, std::string> live = read_settings(cfg.live_path);
    camera.apply_image(live);
    talk.configure(parse_int(live["SPEAKER_VOLUME"], 80), live["TALKBACK_MUTE_MIC"] != "0");
  };

  int status = 0;
  if (!camera.start()) {
    status = 1;
  } else {
    apply_live();
    // With a talk-back socket, the RTSP server offers a backchannel and sends what arrives there.
    std::string info = camera.describe();
    if (talk.start(cfg.talk_path) && !cfg.talk_path.empty()) info += "talk=" + cfg.talk_path + "\n";
    // Frames that arrive before the connection is up are dropped; codec headers are kept.
    out.start(info);
    std::string summary = info;
    for (char &ch : summary)
      if (ch == '\n') ch = ';';
    note("streaming: %s", summary.c_str());
    if (!cfg.on_start.empty())
      std::thread([command = cfg.on_start] { int rc = system(command.c_str()); (void)rc; }).detach();
    uint64_t stats_every = cfg.debug ? 5000000ull : 600000000ull;
    uint64_t next_stats = now_us() + stats_every;
    while (!g_stop && !g_failed) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      if (g_reload.exchange(false)) apply_live();
      if (g_chime.exchange(false)) talk.chime();
      if (const char *name = camera.stalled()) {
        note("no frames from the %s stream for %llu s; restarting the camera", name,
             static_cast<unsigned long long>(kStallUs / 1000000));
        status = 1;
        break;
      }
      if (now_us() >= next_stats) {
        note("%s; dropped %llu", camera.stats().c_str(), static_cast<unsigned long long>(out.dropped()));
        next_stats = now_us() + stats_every;
      }
    }
    if (g_failed) status = 1;
  }

  // A hung camera pipeline can block the teardown calls; don't let that keep the service down.
  std::thread([] {
    std::this_thread::sleep_for(std::chrono::seconds(20));
    note("camera teardown timed out");
    _exit(1);
  }).detach();
  talk.stop();
  camera.stop();
  out.stop();
  note("stopped");
  return status;
}
