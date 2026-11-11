#include "image.h"

#include <camera/CameraMetadata.h>

#include <cmath>
#include <cstdlib>
#include <vector>

#include "common.h"

using namespace qmmf::recorder;

namespace {

// Vendor tags are (section << 16) | index, with sections numbered from 0x8000.
const uint32_t kVendorSections = 0x8000, kMaxSections = 512, kMaxIndex = 512;

std::string tag_name(uint32_t tag) {
  const char *section = get_camera_metadata_section_name(tag);
  const char *name = get_camera_metadata_tag_name(tag);
  if (!section || !name) return "";
  return std::string(section) + "." + name;
}

std::string values(const camera_metadata_ro_entry_t &e) {
  std::string out;
  char buf[48];
  size_t shown = e.count < 8 ? e.count : 8;
  for (size_t i = 0; i < shown; ++i) {
    switch (e.type) {
      case TYPE_BYTE: snprintf(buf, sizeof(buf), "%u", e.data.u8[i]); break;
      case TYPE_INT32: snprintf(buf, sizeof(buf), "%d", e.data.i32[i]); break;
      case TYPE_FLOAT: snprintf(buf, sizeof(buf), "%g", e.data.f[i]); break;
      case TYPE_INT64: snprintf(buf, sizeof(buf), "%lld", static_cast<long long>(e.data.i64[i])); break;
      case TYPE_DOUBLE: snprintf(buf, sizeof(buf), "%g", e.data.d[i]); break;
      case TYPE_RATIONAL: snprintf(buf, sizeof(buf), "%d/%d", e.data.r[i].numerator, e.data.r[i].denominator); break;
      default: snprintf(buf, sizeof(buf), "?"); break;
    }
    if (!out.empty()) out += ' ';
    out += buf;
  }
  if (e.count > shown) out += " ...";
  return out;
}

const char *const kTypes[] = {"byte", "int32", "float", "int64", "double", "rational"};

}  // namespace

void ImageControl::init() {
  vendor_.clear();
  for (uint32_t s = kVendorSections; s < kVendorSections + kMaxSections; ++s) {
    for (uint32_t i = 0; i < kMaxIndex; ++i) {
      uint32_t t = (s << 16) | i;
      std::string name = tag_name(t);
      if (name.empty()) {
        if (i == 0) break;  // no such section
        continue;
      }
      vendor_[name] = t;
    }
  }
}

uint32_t ImageControl::tag(const std::string &name) const {
  auto it = vendor_.find(name);
  if (it != vendor_.end()) return it->second;
  uint32_t t = 0;
  if (android::CameraMetadata::getTagFromName(name.c_str(), nullptr, &t) == 0) return t;
  return 0;
}

void ImageControl::dump(Recorder &recorder, uint32_t camera_id) {
  note("metadata: %zu vendor tags registered", vendor_.size());
  for (const auto &v : vendor_) {
    int type = get_camera_metadata_tag_type(v.second);
    note("metadata: vendor 0x%08x %s %s", v.second, type >= 0 && type <= 5 ? kTypes[type] : "?", v.first.c_str());
  }
  android::CameraMetadata meta;
  status_t ret = recorder.GetCameraParam(camera_id, meta);
  if (ret != 0) {
    note("metadata: GetCameraParam failed (%d)", int(ret));
    return;
  }
  const camera_metadata_t *raw = meta.getAndLock();
  size_t count = get_camera_metadata_entry_count(raw);
  note("metadata: request settings have %zu entries", count);
  for (size_t i = 0; i < count; ++i) {
    camera_metadata_ro_entry_t e;
    if (get_camera_metadata_ro_entry(raw, i, &e) != 0) continue;
    std::string name = tag_name(e.tag);
    note("metadata: 0x%08x %-8s %s = %s", e.tag, e.type <= 5 ? kTypes[e.type] : "?",
         name.empty() ? "(unnamed)" : name.c_str(), values(e).c_str());
  }
  meta.unlock(raw);
}

std::string ImageControl::apply(Recorder &recorder, uint32_t camera_id,
                                const std::map<std::string, std::string> &settings) {
  android::CameraMetadata meta;
  status_t ret = recorder.GetCameraParam(camera_id, meta);
  if (ret != 0) return "GetCameraParam failed (" + std::to_string(ret) + ")";

  auto get = [&settings](const char *key) {
    auto it = settings.find(key);
    return it == settings.end() ? std::string() : it->second;
  };
  // The camera reports its own limits alongside the request settings.
  auto range = [&meta, this](const char *name, int32_t &lo, int32_t &hi) {
    uint32_t t = tag(name);
    camera_metadata_ro_entry_t e = t ? meta.find(t) : camera_metadata_ro_entry_t();
    if (t && e.count >= 2 && e.type == TYPE_INT32) {
      lo = e.data.i32[0];
      hi = e.data.i32[1];
    }
  };
  std::vector<std::pair<std::string, uint32_t>> changed;
  auto set_byte = [&](const char *name, int value) {
    uint32_t t = tag(name);
    uint8_t v = uint8_t(value);
    if (t && meta.update(t, &v, 1) == 0) changed.push_back({name, t});
  };
  auto set_int = [&](const char *name, int value) {
    uint32_t t = tag(name);
    int32_t v = value;
    if (t && meta.update(t, &v, 1) == 0) changed.push_back({name, t});
  };
  auto clamp = [](int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; };

  std::string flicker = get("ANTIFLICKER");
  if (!flicker.empty())
    set_byte("android.control.aeAntibandingMode", flicker == "off" ? 0 : flicker == "50" ? 1 : flicker == "60" ? 2 : 3);

  std::string ev = get("EXPOSURE_EV");
  if (!ev.empty()) {
    int32_t lo = -12, hi = 12;
    range("android.control.aeCompensationRange", lo, hi);
    double step = 1.0 / 6;
    uint32_t t = tag("android.control.aeCompensationStep");
    camera_metadata_ro_entry_t e = t ? meta.find(t) : camera_metadata_ro_entry_t();
    if (t && e.count == 1 && e.type == TYPE_RATIONAL && e.data.r[0].denominator)
      step = double(e.data.r[0].numerator) / e.data.r[0].denominator;
    set_int("android.control.aeExposureCompensation", clamp(int(lround(atof(ev.c_str()) / step)), lo, hi));
  }

  static const char *const kWhiteBalance[] = {"off", "auto", "incandescent", "fluorescent", "warm-fluorescent",
                                              "daylight", "cloudy", "twilight", "shade"};
  std::string wb = get("WHITE_BALANCE");
  for (int i = 1; i < 9 && !wb.empty(); ++i)
    if (wb == kWhiteBalance[i]) set_byte("android.control.awbMode", i);

  struct Level {
    const char *key, *tag, *range;
    int32_t lo, hi;
  };
  const Level levels[] = {
      {"SATURATION", "org.codeaurora.qcamera3.saturation.use_saturation", "org.codeaurora.qcamera3.saturation.range", 0, 10},
      {"SHARPNESS", "org.codeaurora.qcamera3.sharpness.strength", "org.codeaurora.qcamera3.sharpness.range", 0, 6},
  };
  for (const Level &l : levels) {
    std::string value = get(l.key);
    if (value.empty()) continue;
    int32_t lo = l.lo, hi = l.hi;
    if (l.range) range(l.range, lo, hi);
    set_int(l.tag, clamp(parse_int(value, (lo + hi) / 2), lo, hi));
  }

  // RAW: "section.name=value;..." for experiments (numbers only).
  std::string list = get("RAW");
  size_t pos = 0;
  while (pos < list.size()) {
    size_t end = list.find(';', pos);
    if (end == std::string::npos) end = list.size();
    std::string item = list.substr(pos, end - pos);
    pos = end + 1;
    size_t eq = item.find('=');
    if (eq == std::string::npos) continue;
    std::string name = item.substr(0, eq);
    int value = parse_int(item.substr(eq + 1), 0);
    uint32_t t = tag(name);
    int type = t ? get_camera_metadata_tag_type(t) : -1;
    if (type == TYPE_BYTE) set_byte(name.c_str(), value);
    else if (type == TYPE_INT32) set_int(name.c_str(), value);
  }

  ret = recorder.SetCameraParam(camera_id, meta);
  if (ret != 0) return "SetCameraParam failed (" + std::to_string(ret) + ")";

  // Read back what the camera kept.
  android::CameraMetadata now;
  if (recorder.GetCameraParam(camera_id, now) != 0) return "applied; read-back failed";
  std::string summary;
  for (const auto &c : changed) {
    camera_metadata_ro_entry_t e = now.find(c.second);
    std::string short_name = c.first.substr(c.first.rfind('.') + 1);
    summary += (summary.empty() ? "" : ", ") + short_name + "=" + (e.count ? values(e) : std::string("(not kept)"));
  }
  return summary.empty() ? "camera defaults" : summary;
}
