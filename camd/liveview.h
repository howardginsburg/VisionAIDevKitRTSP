// HDMI live view for vaidk-camd: shows a video track's frames full screen on the camera's HDMI output.
// qmmf-server has no display service on this camera; instead Qualcomm's display client
// (libqmmf_display_client) is a client of the display server, weston: it copies each frame into a
// buffer of its own and hands that to weston, which shows it on a display plane, scaled to the screen.
// If weston goes away, the client's next frame aborts vaidk-camd (the camera's libwayland gives up on a
// broken connection); systemd starts it again, and camera/camd.sh starts weston first.
#pragma once

#include <cstdint>
#include <memory>
#include <mutex>

namespace qmmf {
struct BufferDescriptor;
namespace display {
class Display;
}
}  // namespace qmmf

class LiveView {
 public:
  LiveView();
  ~LiveView();
  // Connects to weston and creates a full-screen surface for NV12 frames of this size. False (with a
  // note) when weston doesn't answer.
  bool open(uint32_t width, uint32_t height, uint32_t fps);
  // Queues a frame, NV12 as qmmf lays it out; called from qmmf's callback threads.
  void show(const qmmf::BufferDescriptor &frame);
  void close();

 private:
  bool fail(const char *what, int ret);
  void close_locked();

  std::mutex lock_;
  std::unique_ptr<qmmf::display::Display> display_;
  struct Param;
  std::unique_ptr<Param> param_;
  bool connected_ = false, created_ = false, surfaced_ = false;
  uint32_t surface_ = 0, width_ = 0, height_ = 0, stride_ = 0, frame_size_ = 0;
};
