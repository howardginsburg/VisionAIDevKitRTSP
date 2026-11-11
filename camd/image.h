// Image controls for vaidk-camd: anti-flicker, exposure, white balance, saturation and sharpness,
// applied through the camera's request settings (qmmf GetCameraParam/SetCameraParam). The camera
// reports its limits (compensation range and step, saturation and sharpness ranges) in the same
// settings, and applies changes to the running streams.
#pragma once

#include <cstring>

#include <qmmf-sdk/qmmf_recorder.h>

#include <map>
#include <string>

class ImageControl {
 public:
  // Call after the recorder has connected: that registers the camera's vendor tag names.
  void init();
  // Logs every entry of the current request settings: tag, type and values.
  void dump(qmmf::recorder::Recorder &recorder, uint32_t camera_id);
  // Applies the image settings in `settings` and returns a one-line summary (or the error).
  std::string apply(qmmf::recorder::Recorder &recorder, uint32_t camera_id,
                    const std::map<std::string, std::string> &settings);

 private:
  uint32_t tag(const std::string &name) const;  // "section.name" -> tag; 0 when unknown
  std::map<std::string, uint32_t> vendor_;
};
