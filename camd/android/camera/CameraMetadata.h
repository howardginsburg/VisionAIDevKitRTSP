// Declarations matching Android's camera metadata classes as built into the camera's
// libcamera_client.so.0 and libcamera_metadata.so.0, which vaidk-camd links against at run time.
// That build uses the Android 7 layout of CameraMetadata: no virtual functions, a buffer pointer
// and a lock flag. Only the members vaidk-camd uses are declared.
#pragma once

#include <stddef.h>
#include <stdint.h>

extern "C" {

typedef struct camera_metadata camera_metadata_t;

typedef struct camera_metadata_rational {
  int32_t numerator;
  int32_t denominator;
} camera_metadata_rational_t;

typedef struct camera_metadata_ro_entry {
  size_t index;
  uint32_t tag;
  uint8_t type;
  size_t count;
  union {
    const uint8_t *u8;
    const int32_t *i32;
    const float *f;
    const int64_t *i64;
    const double *d;
    const camera_metadata_rational_t *r;
  } data;
} camera_metadata_ro_entry_t;

// Entry types, as returned by get_camera_metadata_tag_type().
enum { TYPE_BYTE = 0, TYPE_INT32 = 1, TYPE_FLOAT = 2, TYPE_INT64 = 3, TYPE_DOUBLE = 4, TYPE_RATIONAL = 5 };

// Names and types of standard tags, and of vendor tags once a client has registered the camera's
// vendor tag descriptor (the qmmf recorder client does that when it connects). NULL or -1 for
// unknown tags.
const char *get_camera_metadata_section_name(uint32_t tag);
const char *get_camera_metadata_tag_name(uint32_t tag);
int get_camera_metadata_tag_type(uint32_t tag);

size_t get_camera_metadata_entry_count(const camera_metadata_t *metadata);
int get_camera_metadata_ro_entry(const camera_metadata_t *metadata, size_t index, camera_metadata_ro_entry_t *entry);

}  // extern "C"

namespace android {

typedef int32_t status_t;
class VendorTagDescriptor;

class CameraMetadata {
 public:
  CameraMetadata();
  CameraMetadata(const CameraMetadata &other);
  ~CameraMetadata();
  CameraMetadata &operator=(const CameraMetadata &other);

  size_t entryCount() const;
  bool isEmpty() const;
  bool exists(uint32_t tag) const;
  camera_metadata_ro_entry_t find(uint32_t tag) const;
  const camera_metadata_t *getAndLock() const;
  status_t unlock(const camera_metadata_t *buffer);
  status_t update(uint32_t tag, const uint8_t *data, size_t count);
  status_t update(uint32_t tag, const int32_t *data, size_t count);
  status_t update(uint32_t tag, const float *data, size_t count);

  // Resolves "section.name" to a tag; vendor tags need the descriptor, standard tags don't.
  static status_t getTagFromName(const char *name, const VendorTagDescriptor *vendor_tags, uint32_t *tag);

 private:
  camera_metadata_t *mBuffer;
  mutable bool mLocked;
};

}  // namespace android
