// Image controls for vaidk-camd: anti-flicker, exposure, white balance, saturation, sharpness and
// digital zoom, applied through the camera's request settings (qmmf GetCameraParam/SetCameraParam).
// The camera reports its limits (compensation range and step, saturation and sharpness ranges, the
// sensor area and the largest zoom) in the same settings, and applies changes to the running streams.
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
  // Digital zoom: every stream is scaled from a crop of the sensor's active area. `zoom` is the
  // factor (1 = the whole picture, up to the camera's limit); `x` and `y` place the crop in the room
  // left over, from 0 (left or top) through 50 (centred) to 100 (right or bottom). Returns "" or the
  // error; `region` receives the crop as "x y width height".
  std::string crop(qmmf::recorder::Recorder &recorder, uint32_t camera_id, double zoom, double x, double y,
                   std::string *region = nullptr);

 private:
  uint32_t tag(const std::string &name) const;  // "section.name" -> tag; 0 when unknown
  std::map<std::string, uint32_t> vendor_;
};
