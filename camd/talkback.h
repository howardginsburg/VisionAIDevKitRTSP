// Talk-back for vaidk-camd: plays the audio that reaches the RTSP server's backchannel (G.711 that
// Frigate's go2rtc relays from a browser's microphone) on the camera's speaker, through qmmf's
// player. The microphones can be muted while the speaker plays so the far end doesn't hear itself.
#pragma once

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace qmmf {
namespace player {
class Player;
}
}  // namespace qmmf

class Talkback {
 public:
  Talkback();
  ~Talkback();
  // Starts the playback thread and, with a non-empty path, binds the datagram socket the RTSP
  // server sends backchannel audio to (format in talkback.cpp). Returns false if binding fails.
  bool start(const std::string &path);
  void stop();
  // Settings that apply while streaming: speaker volume (0-100) and microphone muting.
  void configure(int volume, bool mute_mic);
  // Plays a short two-note chime: the setup page's speaker test.
  void chime();

 private:
  struct Dsp;
  void receive();
  void play();
  void add(const float *samples, size_t count);  // 8 kHz samples into the speaker queue; lock_ held
  bool open_player(std::unique_lock<std::mutex> &lock);
  void feed(std::unique_lock<std::mutex> &lock);
  void close_player(std::unique_lock<std::mutex> &lock);
  bool send(std::unique_lock<std::mutex> &lock, bool eos);
  bool wait_free(std::unique_lock<std::mutex> &lock);
  void set_mute(bool on);

  std::string path_;
  int fd_ = -1;
  std::thread receiver_, player_thread_;
  std::mutex lock_;
  std::condition_variable cv_;
  bool stopping_ = false;
  std::unique_ptr<Dsp> dsp_;
  std::deque<int16_t> queue_;  // 48 kHz samples waiting for the speaker
  uint64_t last_audio_us_ = 0, dropped_ = 0;
  int volume_ = 80;
  bool mute_mic_ = true, volume_changed_ = false;

  // The player (connected once and kept), its current track, and what its callbacks report.
  std::unique_ptr<qmmf::player::Player> player_;
  bool track_ = false;
  int free_ = 0, buffers_ = 0;  // input buffers ready to fill; how many the track has
  bool notified_ = false, eos_ = false, error_ = false;
  uint64_t last_event_us_ = 0, played_ = 0;
  size_t frame_ = 3840;  // samples per player buffer (80 ms)

  // Microphone gains while muted: what they were, and what the muted control reads back as (on this
  // codec a gain below 0 dB reads back 256 higher). Only the playback thread touches these.
  bool muted_ = false;
  long mic_saved_[2] = {-1, -1}, mic_muted_[2] = {-1, -1};
};
