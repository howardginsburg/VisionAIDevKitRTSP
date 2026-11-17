// HDMI live view for vaidk-camd (see liveview.h).
// The qmmf headers use memcpy/memset without including <cstring> themselves.
#include <cstring>

#include "liveview.h"

#include <qmmf-sdk/qmmf_buffer.h>
#include <qmmf-sdk/qmmf_display.h>

#include <unistd.h>

#include <algorithm>

#include "common.h"

namespace display = qmmf::display;

namespace {

// The vendor starts weston with this runtime directory, where its socket is (init_qti_display).
const char *const kRuntimeDir = "/data/misc/qmmf";

uint32_t align(uint32_t value, uint32_t to) { return (value + to - 1) / to * to; }

}  // namespace

struct LiveView::Param {
  display::SurfaceParam surface;
};

LiveView::LiveView() {}

LiveView::~LiveView() { close(); }

bool LiveView::fail(const char *what, int ret) {  // lock_ held
  note("live view: failed to %s (%d)", what, ret);
  close_locked();
  return false;
}

bool LiveView::open(uint32_t width, uint32_t height, uint32_t fps) {
  std::lock_guard<std::mutex> lock(lock_);
  setenv("XDG_RUNTIME_DIR", kRuntimeDir, 0);
  // A weston that has just started may not answer yet, or not offer everything the client needs.
  int ret = 0;
  for (int attempt = 0; attempt < 10; ++attempt) {
    if (attempt) usleep(500000);
    display_.reset(new display::Display());
    ret = display_->Connect();
    if (ret != 0) continue;
    connected_ = true;
    display::DisplayCb cb;
    cb.EventCb = [](display::DisplayEventType, void *, size_t) {};
    cb.VSyncCb = [](int64_t) {};
    ret = display_->CreateDisplay(display::DisplayType::kPrimary, cb);
    if (ret == 0) break;
    close_locked();
  }
  if (!connected_) return fail("connect to the display server (weston)", ret);
  created_ = true;
  display::SurfaceConfig config;
  memset(&config, 0, sizeof(config));
  config.width = width;
  config.height = height;
  config.format = display::SurfaceFormat::kFormatYCbCr420SemiPlanarVenus;
  config.buffer_count = 1;
  config.use_buffer = true;
  config.z_order = 1;
  ret = display_->CreateSurface(config, &surface_);
  if (ret != 0) return fail("create a surface", ret);
  surfaced_ = true;
  param_.reset(new Param());
  display::SurfaceParam &p = param_->surface;
  memset(&p, 0, sizeof(p));
  p.src_rect = {0, 0, float(width), float(height)};
  p.dst_rect = p.src_rect;
  p.surface_blending = display::SurfaceBlending::kBlendingCoverage;
  p.plane_alpha = 0xff;
  p.frame_rate = fps;
  width_ = width;
  height_ = height;
  // NV12 as qmmf lays it out (Venus): rows 128-byte aligned, the luma rows padded to a multiple of 32,
  // then the chroma rows to 16. The display client's buffers have the same layout.
  stride_ = align(width, 128);
  frame_size_ = stride_ * (align(height, 32) + align(height / 2, 16));
  note("live view: %ux%u on the display server (weston)", width, height);
  return true;
}

void LiveView::show(const qmmf::BufferDescriptor &frame) {
  std::lock_guard<std::mutex> lock(lock_);
  if (!surfaced_ || !frame.data || !frame.size) return;
  display::SurfaceBuffer buffer;
  memset(&buffer, 0, sizeof(buffer));
  buffer.format = display::SurfaceFormat::kFormatYCbCr420SemiPlanarVenus;
  display::PlaneInfo &plane = buffer.plane_info[0];
  plane.buf = frame.data;
  plane.ion_fd = frame.fd;
  plane.width = width_;
  plane.height = height_;
  plane.stride = stride_;
  // The display client copies this many bytes into a buffer of its own, which holds exactly one frame.
  plane.size = std::min(frame.size, frame_size_);
  display_->QueueSurfaceBuffer(surface_, buffer, param_->surface);
}

void LiveView::close() {
  std::lock_guard<std::mutex> lock(lock_);
  close_locked();
}

void LiveView::close_locked() {
  if (surfaced_) display_->DestroySurface(surface_);
  if (created_) display_->DestroyDisplay(display::DisplayType::kPrimary);
  if (connected_) display_->Disconnect();
  surfaced_ = created_ = connected_ = false;
  display_.reset();
}
