// Talk-back for vaidk-camd (see talkback.h).
//
// The RTSP server (rtspd.py) sends each backchannel RTP payload to camd's datagram socket
// (CAMD_TALK, /run/vaidk/talk.sock) as one datagram:
//   byte 0      the RTP payload type: 0 = G.711 u-law (PCMU), 8 = G.711 A-law (PCMA), 8 kHz mono
//   bytes 1...  the payload
// On the way to the speaker the audio is decoded, high-passed at 250 Hz (the small speaker can't
// reproduce bass, which would only use up headroom), raised 12 dB under a peak limiter (speech from
// a browser microphone is quiet next to what the speaker can play) and upsampled to 48 kHz, the rate
// the speaker path is known to play. qmmf's player plays it as PCM on the built-in speaker: a track
// opens when audio arrives and closes after a second without any.
//
// Two qmmf player quirks shape this file:
// - DequeueInputBuffer waits for a free buffer in one-second steps and can miss the wakeup when one
//   comes back, so camd only asks for a buffer it knows is free: the player's first input-buffer
//   event gives the count, and every later one means a buffer came back.
// - Each Player::Connect opens /dev/ion and nothing closes it, so camd connects once and keeps the
//   connection, creating and deleting a track for each burst of audio.
#include "talkback.h"

#include <cstring>

#include <qmmf-sdk/qmmf_player.h>

#include <fcntl.h>
#include <poll.h>
#include <sound/asound.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <vector>

#include "common.h"

using namespace qmmf;
using namespace qmmf::player;

namespace {

const uint32_t kTrack = 1;
const uint32_t kRate = 48000, kInRate = 8000;
const int kUp = int(kRate / kInRate);
const size_t kPrebuffer = kRate * 160 / 1000;  // queued before the speaker starts: rides out network jitter
const size_t kMaxQueue = kRate;                // at most a second waits; older audio is dropped
const uint64_t kGapUs = 100000;                // a pause this long sends what's queued, padded with silence
const uint64_t kIdleUs = 1000000;              // the speaker track closes after this long without audio
const uint64_t kTailUs = 400000;               // the microphones stay muted this long after the speaker stops
const float kGain = 3.981f;                    // +12 dB
// -1 dBFS at the 8 kHz samples; upsampling restores the peaks between them, up to about 0.7 dB higher,
// which still stays below full scale.
const float kCeiling = 0.891f;
const char *const kMicControls[2] = {"DEC7 Volume", "DEC8 Volume"};

int16_t ulaw(uint8_t u) {
  u = uint8_t(~u);
  int t = ((u & 0x0F) << 3) + 0x84;
  t <<= (u & 0x70) >> 4;
  return int16_t((u & 0x80) ? 0x84 - t : t - 0x84);
}

int16_t alaw(uint8_t a) {
  a ^= 0x55;
  int t = (a & 0x0F) << 4;
  int segment = (a & 0x70) >> 4;
  t = segment == 0 ? t + 8 : (t + 0x108) << (segment - 1);
  return int16_t((a & 0x80) ? t : -t);
}

double bessel_i0(double x) {
  double sum = 1, term = 1;
  for (int k = 1; k < 30; ++k) {
    term *= (x / (2 * k)) * (x / (2 * k));
    sum += term;
  }
  return sum;
}

// Reads or writes a mono integer control of the sound card's mixer (what tinymix does).
bool mixer(int fd, const char *name, long *value, bool write) {
  snd_ctl_elem_value v;
  memset(&v, 0, sizeof(v));
  v.id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
  strncpy(reinterpret_cast<char *>(v.id.name), name, sizeof(v.id.name) - 1);
  if (write) v.value.integer.value[0] = *value;
  if (ioctl(fd, write ? SNDRV_CTL_IOCTL_ELEM_WRITE : SNDRV_CTL_IOCTL_ELEM_READ, &v) < 0) return false;
  if (!write) *value = v.value.integer.value[0];
  return true;
}

// The player's volume scales the signal linearly (0-100 -> 0.0-1.0), which leaves the top half of
// the setting sounding alike. Squaring it gives the usual audio taper: 80 is about -4 dB, 50 about
// -12 dB and 10 about -40 dB.
int32_t player_level(int volume) { return int32_t((volume * volume + 50) / 100); }

}  // namespace

// 8 kHz speech in, 48 kHz speaker samples out.
struct Talkback::Dsp {
  static const int kTaps = 24;  // per output phase: 144 in all
  float b0, b1, b2, a1, a2, x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  float envelope = 0, release;
  float taps[kUp][kTaps];
  float history[kTaps] = {};

  Dsp() {
    // Second-order Butterworth high-pass at 250 Hz (RBJ audio EQ cookbook).
    const double w0 = 2 * M_PI * 250 / kInRate, alpha = sin(w0) / (2 * M_SQRT1_2), c = cos(w0), a0 = 1 + alpha;
    b0 = b2 = float((1 + c) / 2 / a0);
    b1 = float(-(1 + c) / a0);
    a1 = float(-2 * c / a0);
    a2 = float((1 - alpha) / a0);
    release = float(exp(-1.0 / (0.08 * kInRate)));  // the limiter recovers over about 80 ms
    // Interpolation filter: a sinc cut off at the input's 4 kHz Nyquist frequency under a Kaiser window
    // (beta 5.65: images from 4.6 kHz up measured 57 dB down), split into one phase per output sample.
    const int n = kUp * kTaps;
    const double center = (n - 1) / 2.0, beta = 5.65;
    for (int i = 0; i < n; ++i) {
      double x = (i - center) / kUp, r = (i - center) / center;
      double sinc = x == 0 ? 1 : sin(M_PI * x) / (M_PI * x);
      taps[i % kUp][i / kUp] = float(sinc * bessel_i0(beta * sqrt(1 - r * r)) / bessel_i0(beta));
    }
  }

  void process(const float *in, size_t count, std::deque<int16_t> &out) {
    for (size_t s = 0; s < count; ++s) {
      float x = in[s];
      float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      if (fabsf(y) < 1e-15f) y = 0;  // no denormals in long silences
      x2 = x1;
      x1 = x;
      y2 = y1;
      y1 = y;
      float v = y * kGain;
      float level = fabsf(v);
      envelope = level > envelope ? level : envelope * release;
      if (envelope > kCeiling) v *= kCeiling / envelope;
      memmove(history + 1, history, sizeof(history) - sizeof(history[0]));
      history[0] = v;
      for (int k = 0; k < kUp; ++k) {
        float acc = 0;
        for (int j = 0; j < kTaps; ++j) acc += taps[k][j] * history[j];
        long sample = lrintf(acc * 32767.0f);
        out.push_back(int16_t(sample > 32767 ? 32767 : sample < -32768 ? -32768 : sample));
      }
    }
  }
};

Talkback::Talkback() : dsp_(new Dsp) {}

Talkback::~Talkback() { stop(); }

bool Talkback::start(const std::string &path) {
  if (!path.empty()) {
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
    unlink(path.c_str());
    fd_ = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd_ < 0 || bind(fd_, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
      note("talk-back: can't open %s (%s)", path.c_str(), strerror(errno));
      if (fd_ >= 0) ::close(fd_);
      fd_ = -1;
    } else {
      path_ = path;
      chmod(path_.c_str(), 0600);
      int size = 256 << 10;
      setsockopt(fd_, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
      receiver_ = std::thread([this] { receive(); });
    }
  }
  player_thread_ = std::thread([this] { play(); });
  return path.empty() || fd_ >= 0;
}

void Talkback::stop() {
  {
    std::lock_guard<std::mutex> lock(lock_);
    if (stopping_) return;
    stopping_ = true;
  }
  cv_.notify_all();
  if (receiver_.joinable()) receiver_.join();
  if (player_thread_.joinable()) player_thread_.join();
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
    unlink(path_.c_str());
  }
}

void Talkback::configure(int volume, bool mute_mic) {
  std::lock_guard<std::mutex> lock(lock_);
  volume = volume < 0 ? 0 : volume > 100 ? 100 : volume;
  if (volume != volume_) volume_changed_ = true;
  volume_ = volume;
  mute_mic_ = mute_mic;
  cv_.notify_all();
}

void Talkback::chime() {
  // Two bell-like notes, A5 then E5, at about -15 dBFS before the talk-back gain.
  const struct {
    float hz, seconds;
  } notes[] = {{880.0f, 0.3f}, {659.3f, 0.7f}};
  std::vector<float> samples;
  for (const auto &n : notes) {
    size_t count = size_t(n.seconds * kInRate);
    for (size_t i = 0; i < count; ++i) {
      float t = float(i) / kInRate;
      float envelope = std::min(1.0f, t / 0.005f) * expf(-t * 3 / n.seconds);
      float phase = float(2 * M_PI) * n.hz * t;
      samples.push_back(0.17f * envelope * (sinf(phase) + 0.3f * sinf(2 * phase)));
    }
  }
  std::lock_guard<std::mutex> lock(lock_);
  add(samples.data(), samples.size());
}

void Talkback::add(const float *samples, size_t count) {
  dsp_->process(samples, count, queue_);
  if (queue_.size() > kMaxQueue) {
    size_t drop = queue_.size() - kMaxQueue;
    queue_.erase(queue_.begin(), queue_.begin() + std::ptrdiff_t(drop));
    dropped_ += drop;
  }
  last_audio_us_ = now_us();
  cv_.notify_all();
}

void Talkback::receive() {
  std::vector<uint8_t> packet(4096);
  std::vector<float> samples;
  for (;;) {
    {
      std::lock_guard<std::mutex> lock(lock_);
      if (stopping_) return;
    }
    pollfd p{fd_, POLLIN, 0};
    if (poll(&p, 1, 200) <= 0) continue;
    ssize_t n = recv(fd_, packet.data(), packet.size(), 0);
    if (n < 2 || (packet[0] != 0 && packet[0] != 8)) continue;
    samples.resize(size_t(n) - 1);
    for (size_t i = 0; i < samples.size(); ++i)
      samples[i] = (packet[0] == 0 ? ulaw(packet[i + 1]) : alaw(packet[i + 1])) / 32768.0f;
    std::lock_guard<std::mutex> lock(lock_);
    add(samples.data(), samples.size());
  }
}

void Talkback::play() {
  std::unique_lock<std::mutex> lock(lock_);
  while (!stopping_) {
    cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
    // Gather a little audio first (or the whole burst, if it is shorter).
    while (!stopping_ && queue_.size() < kPrebuffer && now_us() - last_audio_us_ < kGapUs)
      cv_.wait_for(lock, std::chrono::milliseconds(20));
    if (stopping_) break;
    uint64_t dropped = dropped_;
    if (!open_player(lock)) {
      close_player(lock);
      lock.unlock();
      set_mute(false);
      lock.lock();
      // Try again with fresh audio a little later rather than spinning on a failing player.
      cv_.wait_for(lock, std::chrono::seconds(2), [this] { return stopping_; });
      queue_.clear();
      continue;
    }
    feed(lock);
    uint64_t played = played_;
    close_player(lock);
    note("talk-back: speaker off after %.1f s%s", double(played) / kRate,
         dropped_ > dropped ? " (some audio arrived too fast and was dropped)" : "");
    // Keep the microphones muted while the room's echo dies away; a new burst plays straight away.
    if (cv_.wait_for(lock, std::chrono::microseconds(kTailUs), [this] { return stopping_ || !queue_.empty(); }))
      continue;
    lock.unlock();
    set_mute(false);
    lock.lock();
  }
  close_player(lock);
  if (player_) {
    std::unique_ptr<Player> player = std::move(player_);
    lock.unlock();
    player->Disconnect();
    lock.lock();
  }
  lock.unlock();
  set_mute(false);
}

bool Talkback::open_player(std::unique_lock<std::mutex> &lock) {
  free_ = buffers_ = 0;
  notified_ = eos_ = error_ = volume_changed_ = false;
  played_ = 0;
  int32_t volume = volume_;
  bool mute = mute_mic_;
  bool connect = !player_;
  if (connect) player_.reset(new Player);
  Player *player = player_.get();
  lock.unlock();
  if (mute) set_mute(true);

  status_t ret = 0;
  const char *step = "connect to the player";
  if (connect) {
    PlayerCb cb;
    cb.event_cb = [this](EventType type, void *, size_t) {
      if (type != EventType::kError) return;
      std::lock_guard<std::mutex> l(lock_);
      error_ = true;
      cv_.notify_all();
    };
    ret = player->Connect(cb);
  }
  if (ret == 0) {
    TrackCb cb;
    cb.event_cb = [this](uint32_t, EventType type, void *data, size_t size) {
      std::lock_guard<std::mutex> l(lock_);
      if (type == EventType::kInputBufferNotify) {
        if (notified_) {
          ++free_;
        } else if (data && size >= sizeof(InputBufferNotifyParams)) {
          buffers_ = free_ = int(static_cast<InputBufferNotifyParams *>(data)->num_free_buffers);
          notified_ = true;
        }
        last_event_us_ = now_us();
      } else if (type == EventType::kEOSRendered) {
        eos_ = true;
      } else if (type == EventType::kError) {
        error_ = true;
      }
      cv_.notify_all();
    };
    AudioTrackCreateParam p;
    memset(&p, 0, sizeof(p));
    p.sample_rate = kRate;
    p.channels = 1;
    p.bit_depth = 16;
    p.codec = AudioFormat::kPCM;
    p.out_device = AudioOutSubtype::kBuiltIn;
    step = "create the speaker track";
    ret = player->CreateAudioTrack(kTrack, p, cb);
    if (ret == 0) track_ = true;
  }
  if (ret == 0) {
    int32_t level = player_level(volume);
    player->SetAudioTrackParam(kTrack, CodecParamType::kAudioVolumeParamType, &level, sizeof(level));
  }
  if (ret == 0) {
    step = "prepare the speaker";
    ret = player->Prepare();
  }
  if (ret == 0) {
    step = "start the speaker";
    ret = player->Start();
  }
  lock.lock();
  if (ret != 0) {
    note("talk-back: failed to %s (%d)", step, int(ret));
    error_ = true;
    return false;
  }
  // The player offers its input buffers once it is running.
  cv_.wait_for(lock, std::chrono::seconds(1), [this] { return notified_ || error_ || stopping_; });
  if (!notified_) {
    if (!stopping_) note("talk-back: the speaker track never became ready");
    error_ = true;
    return false;
  }
  note("talk-back: speaker on (volume %d%s)", int(volume), mute ? ", microphones muted" : "");
  return true;
}

void Talkback::feed(std::unique_lock<std::mutex> &lock) {
  while (!stopping_ && !error_) {
    uint64_t now = now_us();
    if (queue_.empty() && now - last_audio_us_ >= kIdleUs) return;
    if (volume_changed_) {
      volume_changed_ = false;
      int32_t level = player_level(volume_);
      lock.unlock();
      player_->SetAudioTrackParam(kTrack, CodecParamType::kAudioVolumeParamType, &level, sizeof(level));
      lock.lock();
      continue;
    }
    // Full buffers only, except at the end of a burst; after running dry, build up a cushion again.
    bool quiet = now - last_audio_us_ >= kGapUs;
    size_t need = free_ >= buffers_ ? kPrebuffer : frame_;
    if (free_ > 0 && !queue_.empty() && (queue_.size() >= need || quiet)) {
      if (!send(lock, false)) error_ = true;
      continue;
    }
    if (free_ <= 0 && now - last_event_us_ > 1000000) {
      // A buffer must have come back without its event; ask for one (at worst this waits a second).
      note("talk-back: no buffer event for a second; asking the player anyway");
      free_ = 1;
      last_event_us_ = now;
      continue;
    }
    cv_.wait_for(lock, std::chrono::milliseconds(20));
  }
}

bool Talkback::send(std::unique_lock<std::mutex> &lock, bool eos) {
  --free_;
  Player *player = player_.get();
  lock.unlock();
  std::vector<TrackBuffer> b(1);
  memset(&b[0], 0, sizeof(b[0]));
  status_t ret = player->DequeueInputBuffer(kTrack, b);
  lock.lock();
  if (ret != 0 || b.size() != 1 || !b[0].data || b[0].size < 2) {
    note("talk-back: no speaker buffer (%d)", int(ret));
    return false;
  }
  size_t room = b[0].size / 2, n = 0;
  int16_t *pcm = static_cast<int16_t *>(b[0].data);
  if (!eos) {
    n = std::min(room, queue_.size());
    std::copy(queue_.begin(), queue_.begin() + std::ptrdiff_t(n), pcm);
    queue_.erase(queue_.begin(), queue_.begin() + std::ptrdiff_t(n));
    frame_ = room;
  }
  lock.unlock();
  if (!eos) std::fill(pcm + n, pcm + room, int16_t(0));  // the last piece of a burst is padded with silence
  b[0].filled_size = eos ? 0 : room * 2;
  b[0].time_stamp = played_ * 1000000ull / kRate;
  b[0].flag = eos ? static_cast<uint32_t>(BufferFlags::kFlagEOS) : 0;
  ret = player->QueueInputBuffer(kTrack, b, nullptr, 0, TrackMetaBufferType::kNone);
  lock.lock();
  if (!eos) played_ += room;
  if (ret != 0) note("talk-back: speaker buffer rejected (%d)", int(ret));
  return ret == 0;
}

bool Talkback::wait_free(std::unique_lock<std::mutex> &lock) {
  uint64_t deadline = now_us() + 1000000;
  while (free_ <= 0 && !error_ && !stopping_ && now_us() < deadline) cv_.wait_for(lock, std::chrono::milliseconds(20));
  if (free_ <= 0 && !error_ && !stopping_) free_ = 1;  // as in feed(): ask anyway
  return !error_ && !stopping_;
}

void Talkback::close_player(std::unique_lock<std::mutex> &lock) {
  if (!player_) return;
  Player *player = player_.get();
  if (track_) {
    // An empty buffer marked end-of-stream lets everything queued play out.
    if (notified_ && !error_ && !stopping_ && wait_free(lock) && send(lock, true))
      cv_.wait_for(lock, std::chrono::seconds(2), [this] { return eos_ || error_ || stopping_; });
    track_ = false;
    lock.unlock();
    player->Stop();
    player->DeleteAudioTrack(kTrack);
    lock.lock();
  }
  if (error_) {
    // Start over with a new connection next time (the old one's /dev/ion stays open).
    lock.unlock();
    player->Disconnect();
    lock.lock();
    player_.reset();
  }
}

void Talkback::set_mute(bool on) {
  if (on == muted_) return;
  int fd = ::open("/dev/snd/controlC0", O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    note("talk-back: can't open the mixer (%s)", strerror(errno));
    return;
  }
  for (int i = 0; i < 2; ++i) {
    if (on) {
      long zero = 0;
      mic_saved_[i] = mic_muted_[i] = -1;
      if (mixer(fd, kMicControls[i], &mic_saved_[i], false) && mixer(fd, kMicControls[i], &zero, true))
        mixer(fd, kMicControls[i], &mic_muted_[i], false);
    } else {
      // Restore only if nothing else changed the gain meanwhile (mic.sh after a settings change).
      long now = -1;
      if (mic_muted_[i] >= 0 && mixer(fd, kMicControls[i], &now, false) && now == mic_muted_[i])
        mixer(fd, kMicControls[i], &mic_saved_[i], true);
    }
  }
  ::close(fd);
  muted_ = on;
}
