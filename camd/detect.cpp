// vaidk-detect: runs the camera's own object detector on frames from vaidk-camd and reports what it
// sees. The detector is Qualcomm's video analytics manager (VAM), loaded from the camera's
// libvam_interface.so.0 through the interface Qualcomm published with qmmf-webserver
// (third_party/qmmf-webserver). VAM gives each frame to its ML engine
// (/usr/lib/vam_engines/libEngine_ML.so.0), which runs the model with SNPE on the Hexagon DSP or the
// CPU, as /data/misc/camera/va-snpe-engine-library_config.json says.
//
// vaidk-camd connects to DETECT_SOCKET and sends a frame whenever the detector asks for one
// (detect_link.h). The detector keeps the objects named in DETECT_OBJECTS that reach DETECT_CONFIDENCE
// percent, sends their boxes back for the main stream, writes what it sees to DETECT_STATE and
// DETECT_RECENT, and sends what changes to the MQTT service, as text datagrams to DETECT_EVENTS (see
// device/mqtt/mqttd.py). It exits when VAM won't start or stops answering, and systemd starts it again.
// The qmmf headers use memcpy/memset without including <cstring> themselves.
#include <cstring>

#include <qmmf-sdk/qmmf_recorder_params.h>

#include "qmmf_vam_interface.h"

#include <dlfcn.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <ctime>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "common.h"
#include "detect_link.h"

using qmmf::BufferDescriptor;
using qmmf::BufferFormat;
using qmmf::CameraBufferMetaData;
using qmmf::recorder::MetaData;
using qmmf::recorder::MetaParamType;

namespace {

const uint32_t kSession = 1, kTrack = 3;  // VAM only hands these back
const size_t kSlots = 2;
const uint64_t kVamQuietUs = 20000000;  // restart when VAM holds a frame this long without a word
const char kVamLibrary[] = "libvam_interface.so.0";
const char kVamFactory[] = "_ZN4qmmf12vaminterface19VAMInterfaceFactory11NewInstanceEPNS0_5VAMCbE";
// libvam_interface uses qmmf's packet queue without naming its library; Qualcomm's media server links
// it itself.
const char kVamCompanion[] = "libav_queue.so.0";

std::atomic<bool> g_stop(false);

// ----- a small JSON reader, for VAM's results and the engine's configuration -----

struct Json {
  enum Kind { kNull, kBool, kNumber, kString, kArray, kObject };
  Kind kind = kNull;
  double number = 0;
  std::string text;
  std::vector<Json> items;
  std::vector<std::pair<std::string, Json>> fields;

  const Json &operator[](const char *key) const {
    static const Json null;
    for (const auto &f : fields)
      if (f.first == key) return f.second;
    return null;
  }
  double num(double fallback = 0) const {
    if (kind == kNumber || kind == kBool) return number;
    if (kind == kString && !text.empty()) {
      char *end = nullptr;
      double v = strtod(text.c_str(), &end);
      if (end && *end == '\0') return v;
    }
    return fallback;
  }
  std::string str() const {
    if (kind == kString) return text;
    if (kind == kNumber) {
      char buf[32];
      snprintf(buf, sizeof(buf), "%g", number);
      return buf;
    }
    return "";
  }
};

class JsonReader {
 public:
  JsonReader(const char *text, size_t size) : p_(text), end_(text + size) {}

  bool parse(Json &out) {
    if (!value(out, 0)) return false;
    space();
    while (p_ < end_ && *p_ == '\0') ++p_;
    return p_ == end_;
  }

 private:
  void space() {
    while (p_ < end_ && (*p_ == ' ' || *p_ == '\t' || *p_ == '\n' || *p_ == '\r')) ++p_;
  }
  bool take(char c) {
    space();
    if (p_ < end_ && *p_ == c) {
      ++p_;
      return true;
    }
    return false;
  }
  bool string(std::string &out) {
    if (!take('"')) return false;
    while (p_ < end_ && *p_ != '"') {
      char c = *p_++;
      if (c != '\\') {
        out += c;
        continue;
      }
      if (p_ >= end_) return false;
      char e = *p_++;
      switch (e) {
        case 'n': out += '\n'; break;
        case 't': out += '\t'; break;
        case 'r': out += '\r'; break;
        case 'b': out += '\b'; break;
        case 'f': out += '\f'; break;
        case 'u':
          if (end_ - p_ < 4) return false;
          p_ += 4;
          out += '?';
          break;
        default: out += e;
      }
    }
    if (p_ >= end_) return false;
    ++p_;
    return true;
  }
  bool value(Json &out, int depth) {
    if (depth > 32) return false;
    space();
    if (p_ >= end_) return false;
    char c = *p_;
    if (c == '{') {
      ++p_;
      out.kind = Json::kObject;
      if (take('}')) return true;
      do {
        std::string key;
        space();
        if (!string(key) || !take(':')) return false;
        out.fields.emplace_back(key, Json());
        if (!value(out.fields.back().second, depth + 1)) return false;
      } while (take(','));
      return take('}');
    }
    if (c == '[') {
      ++p_;
      out.kind = Json::kArray;
      if (take(']')) return true;
      do {
        out.items.emplace_back();
        if (!value(out.items.back(), depth + 1)) return false;
      } while (take(','));
      return take(']');
    }
    if (c == '"') {
      out.kind = Json::kString;
      return string(out.text);
    }
    static const struct { const char *word; Json::Kind kind; double number; } kWords[] = {
        {"true", Json::kBool, 1}, {"false", Json::kBool, 0}, {"null", Json::kNull, 0}};
    for (const auto &w : kWords) {
      size_t n = strlen(w.word);
      if (size_t(end_ - p_) >= n && strncmp(p_, w.word, n) == 0) {
        p_ += n;
        out.kind = w.kind;
        out.number = w.number;
        return true;
      }
    }
    char *stop = nullptr;
    out.number = strtod(p_, &stop);
    if (!stop || stop == p_ || stop > end_) return false;
    p_ = stop;
    out.kind = Json::kNumber;
    return true;
  }

  const char *p_;
  const char *end_;
};

bool parse_json(const std::string &text, Json &out) { return JsonReader(text.data(), text.size()).parse(out); }

// ----- settings -----

// Trims spaces and control characters: VAM's labels end with the labels file's line break.
std::string trim(std::string s) {
  auto junk = [](char c) { return static_cast<unsigned char>(c) <= ' '; };
  while (!s.empty() && junk(s.back())) s.pop_back();
  size_t start = 0;
  while (start < s.size() && junk(s[start])) ++start;
  return s.substr(start);
}

std::string lower(std::string s) {
  for (char &c : s)
    if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
  return s;
}

struct Settings {
  std::string socket_path, state_path, recent_path, config_path, events_path;
  std::set<std::string> objects;  // empty: every label
  double confidence;              // percent
  uint32_t hold_s, debug;
};

Settings load_settings() {
  Settings s;
  s.socket_path = env_str("DETECT_SOCKET", "/run/vaidk/detect.sock");
  s.state_path = env_str("DETECT_STATE", "/run/vaidk/detect.state");
  s.recent_path = env_str("DETECT_RECENT", "/run/vaidk/detect.recent");
  s.config_path = env_str("DETECT_ENGINE_CONFIG", "/data/misc/camera/va-snpe-engine-library_config.json");
  s.events_path = env_str("DETECT_EVENTS", "/run/vaidk/events.sock");
  // Comma-separated labels; an underscore stands for a space ("teddy_bear"), as the settings file
  // can't hold spaces.
  std::string list = env_str("DETECT_OBJECTS", "person");
  for (char &c : list)
    if (c == '_') c = ' ';
  size_t start = 0;
  while (start <= list.size()) {
    size_t comma = list.find(',', start);
    if (comma == std::string::npos) comma = list.size();
    std::string label = lower(trim(list.substr(start, comma - start)));
    if (!label.empty()) s.objects.insert(label);
    start = comma + 1;
  }
  if (s.objects.count("all")) s.objects.clear();
  s.confidence = env_u32("DETECT_CONFIDENCE", 60);
  s.hold_s = env_u32("DETECT_HOLD", 3);
  s.debug = env_u32("DETECT_DEBUG", 0);
  return s;
}

std::string read_text(const std::string &path) {
  std::string out;
  FILE *f = fopen(path.c_str(), "r");
  if (!f) return out;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.append(buf, n);
  fclose(f);
  return out;
}

void write_file(const std::string &path, const std::string &text) {
  std::string tmp = path + ".tmp";
  FILE *f = fopen(tmp.c_str(), "w");
  if (!f) return;
  fputs(text.c_str(), f);
  if (fclose(f) == 0) rename(tmp.c_str(), path.c_str());
}

// ----- SNPE's version and runtimes, read from the library the ML engine uses -----

namespace snpe {
struct Version {  // zdl::DlSystem::Version_t in SNPE 1.x
  int32_t major, minor, teeny;
  std::string build;
};
}  // namespace snpe

std::string snpe_summary() {
  void *lib = dlopen("libSNPE.so", RTLD_NOW | RTLD_GLOBAL);
  if (!lib) return std::string("SNPE not loaded: ") + dlerror();
  using VersionFn = snpe::Version (*)();
  using AvailableFn = bool (*)(int);
  auto version = reinterpret_cast<VersionFn>(dlsym(lib, "_ZN3zdl4SNPE11SNPEFactory17getLibraryVersionEv"));
  auto available =
      reinterpret_cast<AvailableFn>(dlsym(lib, "_ZN3zdl4SNPE11SNPEFactory18isRuntimeAvailableENS_8DlSystem9Runtime_tE"));
  std::string out = "SNPE";
  if (version) {
    snpe::Version v = version();
    char buf[96];
    snprintf(buf, sizeof(buf), " %d.%d.%d", v.major, v.minor, v.teeny);
    out += buf;
    if (!v.build.empty()) out += " (" + v.build + ")";
  }
  if (available) {
    out += available(2) ? ", DSP available" : ", DSP not available";  // Runtime_t::DSP
    out += available(0) ? ", CPU available" : ", CPU not available";  // Runtime_t::CPU
  }
  return out;
}

// ----- labels -----

enum Kind { kPeople, kVehicles, kAnimals, kOther };
const uint32_t kColors[] = {0xFFC800FF, 0x00C8FFFF, 0x7CFC00FF, 0xFFFFFFFF};  // RGBA: amber, sky blue, green, white

Kind kind_of(const std::string &label) {
  static const std::set<std::string> vehicles = {"bicycle", "car", "motorcycle", "airplane",
                                                 "bus", "train", "truck", "boat"};
  static const std::set<std::string> animals = {"bird", "cat", "dog", "horse", "sheep",
                                                "cow", "elephant", "bear", "zebra", "giraffe"};
  if (label == "person") return kPeople;
  if (vehicles.count(label)) return kVehicles;
  if (animals.count(label)) return kAnimals;
  return kOther;
}

struct Found {
  std::string label;
  double confidence;  // percent
  uint16_t x, y, width, height;
};

uint16_t tenthousandths(double v) { return uint16_t(std::max(0.0, std::min(10000.0, v))); }

class Detector : public qmmf::vaminterface::VAMCb {
 public:
  explicit Detector(const Settings &s) : s_(s), started_at_(time(nullptr)) {
    // What the detector sees goes to the MQTT service as datagrams; nobody may be listening.
    events_fd_ = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    events_addr_.sun_family = AF_UNIX;
    strncpy(events_addr_.sun_path, s_.events_path.c_str(), sizeof(events_addr_.sun_path) - 1);
  }

  bool load() {
    snpe_ = snpe_summary();
    note("%s", snpe_.c_str());
    Json config;
    if (parse_json(read_text(s_.config_path), config)) {
      model_ = config["DLC_NAME"].str();
      if (model_.empty()) model_ = config["MODEL_FILENAME"].str();
      runtime_ = config["Runtime"].num(1) == 0 ? "CPU" : "DSP";
    } else {
      note("can't read the engine configuration %s", s_.config_path.c_str());
    }
    if (!dlopen(kVamCompanion, RTLD_NOW | RTLD_GLOBAL))
      return fail(std::string("can't load ") + kVamCompanion + ": " + dlerror());
    void *lib = dlopen(kVamLibrary, RTLD_NOW);
    if (!lib) return fail(std::string("can't load ") + kVamLibrary + ": " + dlerror());
    using Factory = qmmf::vaminterface::VAMInterface *(*)(qmmf::vaminterface::VAMCb *);
    auto factory = reinterpret_cast<Factory>(dlsym(lib, kVamFactory));
    if (!factory) return fail(std::string("no VAM factory in ") + kVamLibrary);
    vam_ = factory(this);
    if (!vam_ || vam_->InitVAM(kSession, kTrack) != 0) return fail("VAM didn't initialise");
    status_ = "waiting";
    write_state(true);
    return true;
  }

  void stop() {
    if (vam_ && started_) vam_->CloseVAM();
    if (status_ != "error") status_ = "stopped";
    write_state(true);
  }

  // A connection from vaidk-camd; frames still in VAM come back to the old slots.
  void attach(int fd) {
    {
      std::lock_guard<std::mutex> lock(send_lock_);
      fd_ = fd;
    }
    want(1);
  }
  void detach() {
    std::lock_guard<std::mutex> lock(send_lock_);
    fd_ = -1;
  }

  // Reads one message from vaidk-camd; false when the connection is gone or broken.
  bool receive(int fd) {
    detect::Header h;
    if (!read_full(fd, &h, sizeof(h))) return false;
    if (h.magic != detect::kMagic || h.length > detect::kMaxFrame + sizeof(detect::FrameInfo)) {
      note("unexpected message from vaidk-camd");
      return false;
    }
    if (h.type != detect::kFrame || h.length < sizeof(detect::FrameInfo)) return skip(fd, h.length);
    detect::FrameInfo info;
    if (!read_full(fd, &info, sizeof(info))) return false;
    size_t size = h.length - sizeof(info);
    int slot = take_slot();
    if (slot < 0) {
      ++dropped_;
      return skip(fd, size);
    }
    std::vector<uint8_t> &data = slots_[slot].data;
    if (data.size() < size) data.resize(size);
    if (!read_full(fd, data.data(), size)) {
      release(slot);
      return false;
    }
    process(slot, info, size);
    return true;
  }

  void tick() {
    uint64_t now = now_us();
    bool changed = false, stuck = false;
    std::string event;
    {
      std::lock_guard<std::mutex> lock(state_lock_);
      for (auto &e : seen_) {
        if (e.second.present && now - e.second.last_us > uint64_t(s_.hold_s) * 1000000u) {
          e.second.present = false;
          e.second.held = 0;
          state_line(event, e.first, 0);
          changed = true;
        }
      }
      // VAM may report nothing at all for a frame without objects: clear the boxes once a result is
      // overdue, allowing for the time between the frames it is given (a second at 1 a second).
      uint64_t overdue = std::max<uint64_t>(700000, queue_gap_us_ * 3 / 2);
      if (boxes_shown_ && now - last_result_us_ > overdue) {
        boxes_shown_ = false;
        pending_clear_ = true;
      }
      // VAM keeps each frame until it has analysed it. Holding one this long means it (or the DSP) hangs.
      bool holding = false;
      for (const Slot &slot : slots_) holding = holding || slot.busy;
      uint64_t heard = std::max({last_result_us_, last_returned_us_, last_queued_us_});
      stuck = started_ && holding && heard && now - heard > kVamQuietUs;
    }
    if (stuck && !g_stop) {
      fail("VAM stopped answering; restarting");
      g_stop = true;
      exit_code_ = 4;
      return;
    }
    emit(event);
    if (pending_clear_) {
      pending_clear_ = false;
      send_boxes({});
    }
    if (changed || now - last_state_us_ > 1000000) write_state(changed);
    if (now >= next_log_us_) {
      if (next_log_us_) log_stats();
      next_log_us_ = now + 60000000ull;
    }
  }

  // VAMCb: results (JSON) for a frame.
  int32_t SendVAMMeta(uint32_t, uint32_t, const char *text, size_t size, int64_t pts) override {
    uint64_t now = now_us();
    std::string json(text, size);
    if (debug_left_ < s_.debug) {
      ++debug_left_;
      note("VAM result %u: %s", debug_left_, json.c_str());
    }
    Json root;
    if (!parse_json(json, root)) {
      if (bad_json_++ < 3) note("VAM sent something unexpected: %.200s", json.c_str());
      return 0;
    }
    const Json &objects = root["objects"];
    std::vector<Found> kept;
    std::string event;  // for the MQTT service (events_path): what changed, and this result's objects
    for (const Json &o : objects.items) {
      Found f;
      f.label = lower(trim(o["display_name"].str()));
      if (f.label.empty()) f.label = lower(trim(o["label"].str()));
      f.confidence = o["confidence"].num(0);
      if (f.confidence <= 1.0) f.confidence *= 100.0;
      const Json &p = o["position"];
      f.x = tenthousandths(p["x"].num(0));
      f.y = tenthousandths(p["y"].num(0));
      f.width = tenthousandths(p["width"].num(0));
      f.height = tenthousandths(p["height"].num(0));
      if (f.label.empty() || f.confidence < s_.confidence) continue;
      if (!s_.objects.empty() && !s_.objects.count(f.label)) continue;
      kept.push_back(f);
    }
    std::sort(kept.begin(), kept.end(), [](const Found &a, const Found &b) {
      Kind ka = kind_of(a.label), kb = kind_of(b.label);
      return ka != kb ? ka < kb : a.confidence > b.confidence;
    });
    {
      std::lock_guard<std::mutex> lock(state_lock_);
      ++results_;
      result_times_.push_back(now);
      while (!result_times_.empty() && now - result_times_.front() > 10000000) result_times_.pop_front();
      auto queued = queued_at_.find(uint64_t(pts));
      if (queued != queued_at_.end()) {
        record_latency(now - queued->second);
        queued_at_.erase(queued_at_.begin(), std::next(queued));
      } else if (last_queued_us_) {
        record_latency(now - last_queued_us_);
      }
      last_result_us_ = now;
      std::map<std::string, int> counts;
      std::map<std::string, double> best;
      for (const Found &f : kept) {
        ++counts[f.label];
        best[f.label] = std::max(best[f.label], f.confidence);
      }
      for (auto &e : seen_) e.second.now = 0;
      time_t wall = time(nullptr);
      for (const auto &c : counts) {
        Seen &s = seen_[c.first];
        s.now = c.second;
        s.last_us = now;
        s.last_wall = wall;
        s.confidence = best[c.first];
        // How many are in view: a rise counts at once, a fall once the lower count has held for the
        // hold time, so one of two people missed now and then doesn't make the count flicker.
        int held = s.held;
        if (!s.present || c.second >= s.held) {
          held = c.second;
          s.held_us = now;
        } else if (now - s.held_us > uint64_t(s_.hold_s) * 1000000u) {
          held = c.second;
          s.held_us = now;
        }
        if (!s.present || held != s.held) state_line(event, c.first, held);
        s.held = held;
        if (!s.present) {
          s.present = true;
          char line[96];
          snprintf(line, sizeof(line), "%ld|%s|%.0f", long(wall), c.first.c_str(), s.confidence);
          recent_.push_front(line);
          while (recent_.size() > 20) recent_.pop_front();
          recent_changed_ = true;
        }
      }
      boxes_shown_ = !kept.empty();
      // This result's objects while something is in view, then once more with none.
      if (!kept.empty() || had_objects_) {
        timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        char line[96];
        snprintf(line, sizeof(line), "time %ld.%03ld\n", long(ts.tv_sec), long(ts.tv_nsec / 1000000));
        std::string objects = line;
        for (size_t i = 0; i < kept.size() && i < detect::kMaxBoxes; ++i) {
          const Found &f = kept[i];
          snprintf(line, sizeof(line), "object %s %.0f %u %u %u %u\n", underscored(f.label).c_str(), f.confidence,
                   f.x, f.y, f.width, f.height);
          objects += line;
        }
        event = objects + event;
      }
      had_objects_ = !kept.empty();
    }
    emit(event);
    std::vector<detect::Box> boxes;
    for (const Found &f : kept) {
      if (boxes.size() >= detect::kMaxBoxes) break;
      detect::Box b{};
      b.x = f.x;
      b.y = f.y;
      b.width = f.width;
      b.height = f.height;
      b.color = kColors[kind_of(f.label)];
      // qmmf draws up to 19 characters of a box's label.
      snprintf(b.label, sizeof(b.label), "%.14s %.0f%%", f.label.c_str(), f.confidence);
      boxes.push_back(b);
    }
    send_boxes(boxes);
    return 0;
  }

  // VAMCb: VAM is done with a frame.
  int32_t ReturnTrackBuffer(uint32_t, uint32_t, BufferDescriptor &buffer) override {
    {
      std::lock_guard<std::mutex> lock(state_lock_);
      last_returned_us_ = now_us();
      if (buffer.buf_id < kSlots) slots_[buffer.buf_id].busy = false;
    }
    want(1);
    return 0;
  }

 private:
  struct Slot {
    std::vector<uint8_t> data;
    bool busy = false;
  };
  struct Seen {
    int now = 0, held = 0;  // in this result; in view (held, see SendVAMMeta)
    bool present = false;
    uint64_t last_us = 0, held_us = 0;
    time_t last_wall = 0;
    double confidence = 0;
  };

  static std::string underscored(std::string label) {
    for (char &c : label)
      if (c == ' ') c = '_';
    return label;
  }
  static void state_line(std::string &event, const std::string &label, int count) {
    event += "state " + underscored(label) + (count ? " ON " : " OFF ") + std::to_string(count) + "\n";
  }

  // Sends an event to the MQTT service, if it is listening; never waits.
  void emit(const std::string &event) {
    if (event.empty() || events_fd_ < 0) return;
    ssize_t n = sendto(events_fd_, event.data(), event.size(), MSG_DONTWAIT | MSG_NOSIGNAL,
                       reinterpret_cast<const sockaddr *>(&events_addr_), sizeof(events_addr_));
    (void)n;
  }

  bool fail(const std::string &why) {
    note("%s", why.c_str());
    status_ = "error";
    error_ = why;
    write_state(true);
    return false;
  }

  static bool read_full(int fd, void *buf, size_t size) {
    uint8_t *p = static_cast<uint8_t *>(buf);
    while (size) {
      ssize_t n = recv(fd, p, size, MSG_WAITALL);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return false;
      p += n;
      size -= size_t(n);
    }
    return true;
  }
  static bool skip(int fd, size_t size) {
    uint8_t buf[4096];
    while (size) {
      size_t n = std::min(size, sizeof(buf));
      if (!read_full(fd, buf, n)) return false;
      size -= n;
    }
    return true;
  }

  int take_slot() {
    std::lock_guard<std::mutex> lock(state_lock_);
    for (size_t i = 0; i < kSlots; ++i) {
      if (!slots_[i].busy) {
        slots_[i].busy = true;
        return int(i);
      }
    }
    return -1;
  }
  void release(int slot) {
    std::lock_guard<std::mutex> lock(state_lock_);
    slots_[slot].busy = false;
  }

  void send(uint16_t type, const void *payload, uint32_t size) {
    std::vector<uint8_t> m(sizeof(detect::Header) + size);
    detect::Header h{detect::kMagic, type, 0, size};
    memcpy(m.data(), &h, sizeof(h));
    if (size) memcpy(m.data() + sizeof(h), payload, size);
    std::lock_guard<std::mutex> lock(send_lock_);
    if (fd_ < 0) return;
    // Small messages; a full socket means vaidk-camd is stuck, and this one is dropped.
    ssize_t n = ::send(fd_, m.data(), m.size(), MSG_NOSIGNAL | MSG_DONTWAIT);
    if (n != ssize_t(m.size()) && send_failures_++ < 3) note("couldn't send to vaidk-camd (%zd)", n);
  }
  void want(uint32_t frames) { send(detect::kWant, &frames, sizeof(frames)); }
  void send_boxes(const std::vector<detect::Box> &boxes) {
    std::vector<uint8_t> payload(4 + boxes.size() * sizeof(detect::Box));
    uint32_t count = uint32_t(boxes.size());
    memcpy(payload.data(), &count, 4);
    if (count) memcpy(payload.data() + 4, boxes.data(), boxes.size() * sizeof(detect::Box));
    send(detect::kBoxes, payload.data(), uint32_t(payload.size()));
  }

  void process(int slot, const detect::FrameInfo &info, size_t size) {
    CameraBufferMetaData meta;
    memset(&meta, 0, sizeof(meta));
    meta.format = BufferFormat::kNV12;
    meta.num_planes = 2;
    for (int i = 0; i < 2; ++i) {
      // As Qualcomm's media server does: both planes with the picture's width and height.
      meta.plane_info[i].width = info.width;
      meta.plane_info[i].height = info.height;
      meta.plane_info[i].stride = info.stride[i];
      meta.plane_info[i].scanline = info.scanline[i];
      meta.plane_info[i].offset = info.offset[i];
      meta.plane_info[i].size = info.plane_size[i];
    }
    if (!started_) {
      note("first frame: %ux%u, Y stride %u scanline %u offset %u, UV stride %u scanline %u offset %u, %zu bytes",
           info.width, info.height, info.stride[0], info.scanline[0], info.offset[0], info.stride[1],
           info.scanline[1], info.offset[1], size);
      if (info.offset[1] != info.stride[0] * info.scanline[0])
        note("the UV plane isn't where VAM expects it (stride x scanline); colours will be wrong");
      status_ = "starting";
      write_state(true);
      uint64_t t0 = now_us();
      int32_t ret = vam_->StartVAM(meta);
      if (ret != 0) {
        release(slot);
        fail("VAM didn't start (" + std::to_string(ret) + "); see the journal for MLWrapper and VAM lines");
        g_stop = true;
        exit_code_ = 2;
        return;
      }
      started_ = true;
      width_ = info.width;
      height_ = info.height;
      status_ = "running";
      note("VAM started in %llu ms", static_cast<unsigned long long>((now_us() - t0) / 1000));
      write_state(true);
      emit("reset\n");  // a new start: nothing is in view until VAM says so
    } else if (info.width != width_ || info.height != height_) {
      release(slot);
      note("the frame size changed to %ux%u; restarting", info.width, info.height);
      g_stop = true;
      exit_code_ = 3;
      return;
    }
    BufferDescriptor b;
    memset(&b, 0, sizeof(b));
    b.data = slots_[slot].data.data();
    b.fd = -1;
    b.buf_id = uint32_t(slot);
    b.size = uint32_t(size);
    b.capacity = uint32_t(slots_[slot].data.size());
    b.timestamp = info.timestamp;
    MetaData m;
    memset(&m, 0, sizeof(m));
    m.meta_flag = static_cast<uint32_t>(MetaParamType::kCamBufMetaData);
    m.cam_buffer_meta_data = meta;
    std::vector<BufferDescriptor> buffers{b};
    std::vector<MetaData> metas{m};
    uint64_t t0 = now_us();
    {
      std::lock_guard<std::mutex> lock(state_lock_);
      queued_at_[info.timestamp] = t0;
      while (queued_at_.size() > 64) queued_at_.erase(queued_at_.begin());
      // The usual time between frames, smoothed: how long a pause between results is normal.
      if (last_queued_us_ && t0 - last_queued_us_ < 10000000) {
        uint64_t gap = t0 - last_queued_us_;
        queue_gap_us_ = queue_gap_us_ ? (queue_gap_us_ * 3 + gap) / 4 : gap;
      }
      last_queued_us_ = t0;
      ++queued_;
    }
    int32_t ret = vam_->QueueVAMBuffers(kTrack, kSession, buffers, metas);
    uint64_t waited = now_us() - t0;
    {
      std::lock_guard<std::mutex> lock(state_lock_);
      queue_wait_max_us_ = std::max(queue_wait_max_us_, waited);
      if (ret != 0) {
        ++refused_;
        queued_at_.erase(info.timestamp);
      }
    }
    if (ret != 0) {
      release(slot);
      want(1);
    }
  }

  void record_latency(uint64_t us) {  // state_lock_ held
    latency_sum_us_ += us;
    ++latency_count_;
    latency_max_us_ = std::max(latency_max_us_, us);
    recent_latency_.push_back(us);
    while (recent_latency_.size() > 50) recent_latency_.pop_front();
  }

  void write_state(bool force) {
    std::string text;
    {
      std::lock_guard<std::mutex> lock(state_lock_);
      uint64_t now = now_us();
      if (!force && now - last_state_us_ < 1000000) return;
      last_state_us_ = now;
      double rate = result_times_.size() >= 2
                        ? double(result_times_.size() - 1) * 1e6 / double(result_times_.back() - result_times_.front())
                        : 0;
      if (!result_times_.empty() && now - result_times_.back() > 3000000) rate = 0;
      uint64_t latency = 0;
      for (uint64_t l : recent_latency_) latency += l;
      if (!recent_latency_.empty()) latency /= recent_latency_.size();
      char buf[512];
      snprintf(buf, sizeof(buf),
               "status=%s\nerror=%s\nsnpe=%s\nruntime=%s\nmodel=%s\nsince=%ld\nanalysed=%llu\nrate=%.1f\n"
               "latency_ms=%llu\nrefused=%llu\n",
               status_.c_str(), error_.c_str(), snpe_.c_str(), runtime_.c_str(), model_.c_str(), long(started_at_),
               static_cast<unsigned long long>(results_), rate, static_cast<unsigned long long>(latency / 1000),
               static_cast<unsigned long long>(refused_));
      text = buf;
      std::string present;
      for (const auto &e : seen_) {
        if (!e.second.present) continue;
        if (!present.empty()) present += ",";
        present += e.first + " " + std::to_string(e.second.held);
      }
      text += "present=" + present + "\n";
      for (const auto &e : seen_) {
        char line[128];
        snprintf(line, sizeof(line), "seen=%s|%ld|%.0f\n", e.first.c_str(), long(e.second.last_wall),
                 e.second.confidence);
        text += line;
      }
      if (recent_changed_) {
        std::string recent;
        for (const auto &r : recent_) recent += r + "\n";
        recent_changed_ = false;
        write_file(s_.recent_path, recent);
      }
    }
    write_file(s_.state_path, text);
  }

  void log_stats() {
    std::lock_guard<std::mutex> lock(state_lock_);
    double rate = result_times_.size() >= 2
                      ? double(result_times_.size() - 1) * 1e6 / double(result_times_.back() - result_times_.front())
                      : 0;
    note("queued %llu, results %llu (%.1f/s), refused %llu, dropped %llu; latency avg %llu ms, max %llu ms; "
         "longest queue call %llu ms",
         static_cast<unsigned long long>(queued_), static_cast<unsigned long long>(results_), rate,
         static_cast<unsigned long long>(refused_), static_cast<unsigned long long>(dropped_),
         static_cast<unsigned long long>(latency_count_ ? latency_sum_us_ / latency_count_ / 1000 : 0),
         static_cast<unsigned long long>(latency_max_us_ / 1000),
         static_cast<unsigned long long>(queue_wait_max_us_ / 1000));
    latency_sum_us_ = latency_count_ = latency_max_us_ = queue_wait_max_us_ = 0;
  }

 public:
  int exit_code_ = 0;

 private:
  const Settings s_;
  qmmf::vaminterface::VAMInterface *vam_ = nullptr;
  bool started_ = false;
  uint32_t width_ = 0, height_ = 0;
  std::string snpe_, model_, runtime_, status_ = "starting", error_;
  time_t started_at_;
  Slot slots_[kSlots];

  std::mutex send_lock_;
  int fd_ = -1;
  uint32_t send_failures_ = 0;
  int events_fd_ = -1;
  sockaddr_un events_addr_{};

  std::mutex state_lock_;
  std::map<uint64_t, uint64_t> queued_at_;
  std::map<std::string, Seen> seen_;
  std::deque<std::string> recent_;
  std::deque<uint64_t> result_times_, recent_latency_;
  bool recent_changed_ = false, boxes_shown_ = false, had_objects_ = false;
  std::atomic<bool> pending_clear_{false};
  uint64_t results_ = 0, queued_ = 0, refused_ = 0, dropped_ = 0;
  uint64_t last_result_us_ = 0, last_queued_us_ = 0, last_returned_us_ = 0, last_state_us_ = 0, next_log_us_ = 0;
  uint64_t queue_gap_us_ = 0;
  uint64_t latency_sum_us_ = 0, latency_count_ = 0, latency_max_us_ = 0, queue_wait_max_us_ = 0;
  uint32_t debug_left_ = 0, bad_json_ = 0;
};

int listen_socket(const std::string &path) {
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
  unlink(path.c_str());
  if (bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0 || listen(fd, 2) != 0) {
    close(fd);
    return -1;
  }
  chmod(path.c_str(), 0600);
  return fd;
}

}  // namespace

int main() {
  setvbuf(stdout, nullptr, _IOLBF, 0);
  signal(SIGPIPE, SIG_IGN);
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = [](int) { g_stop = true; };
  sigaction(SIGTERM, &sa, nullptr);
  sigaction(SIGINT, &sa, nullptr);

  Settings settings = load_settings();
  Detector detector(settings);
  if (!detector.load()) return 2;
  int listener = listen_socket(settings.socket_path);
  if (listener < 0) {
    note("can't listen at %s: %s", settings.socket_path.c_str(), strerror(errno));
    return 2;
  }
  note("waiting for frames at %s", settings.socket_path.c_str());

  int client = -1;
  while (!g_stop) {
    pollfd p[2] = {{listener, POLLIN, 0}, {client, POLLIN, 0}};
    int n = poll(p, client >= 0 ? 2 : 1, 250);
    if (n < 0 && errno != EINTR) break;
    if (n > 0 && (p[0].revents & POLLIN)) {
      int c = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
      if (c >= 0) {
        if (client >= 0) close(client);
        client = c;
        detector.attach(client);
        note("vaidk-camd connected");
      }
    }
    if (n > 0 && client >= 0 && (p[1].revents & (POLLIN | POLLHUP | POLLERR))) {
      if (!detector.receive(client)) {
        detector.detach();
        close(client);
        client = -1;
        note("vaidk-camd disconnected");
      }
    }
    detector.tick();
  }

  // VAM's teardown can hang with the DSP; don't let that keep the service from restarting.
  std::thread([] {
    std::this_thread::sleep_for(std::chrono::seconds(10));
    note("VAM teardown timed out");
    _exit(1);
  }).detach();
  detector.detach();
  if (client >= 0) close(client);
  close(listener);
  unlink(settings.socket_path.c_str());
  detector.stop();
  note("stopped");
  _exit(detector.exit_code_);
}
