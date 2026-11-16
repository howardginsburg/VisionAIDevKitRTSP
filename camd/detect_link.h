// The messages between vaidk-camd and the object detector (vaidk-detect) on /run/vaidk/detect.sock.
// The detector listens; vaidk-camd connects. Each message is a Header followed by `length` bytes,
// little-endian, both programs built by the same compiler for the same camera.
//   kWant   detector -> camd   uint32_t: how many more frames it can take
//   kFrame  camd -> detector   FrameInfo, then the NV12 picture as qmmf delivered it
//   kBoxes  detector -> camd   uint32_t count, then `count` Box (most important first)
#pragma once

#include <cstdint>

namespace detect {

const uint32_t kMagic = 0x44494156;  // "VAID"
enum : uint16_t { kWant = 1, kFrame = 2, kBoxes = 3 };
const uint32_t kMaxFrame = 4u << 20;
const uint32_t kMaxBoxes = 32;

#pragma pack(push, 1)
struct Header {
  uint32_t magic;
  uint16_t type;
  uint16_t reserved;
  uint32_t length;
};

struct FrameInfo {
  uint64_t timestamp;  // capture time from qmmf, nanoseconds
  uint32_t width, height;
  uint32_t stride[2], scanline[2], offset[2], plane_size[2];  // Y, then interleaved UV
};

// Position and size in ten-thousandths of the picture, as VAM reports them.
struct Box {
  uint16_t x, y, width, height;
  uint32_t color;  // RGBA
  char label[24];
};
#pragma pack(pop)

static_assert(sizeof(Header) == 12, "Header must stay 12 bytes");
static_assert(sizeof(Box) == 36, "Box must stay 36 bytes");

}  // namespace detect
