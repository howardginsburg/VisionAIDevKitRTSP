// Helpers shared by vaidk-camd's source files.
#pragma once

#include <time.h>

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>

inline uint64_t clock_us(clockid_t clock) {
  timespec ts;
  clock_gettime(clock, &ts);
  return uint64_t(ts.tv_sec) * 1000000u + uint64_t(ts.tv_nsec) / 1000u;
}

// qmmf's capture timestamps match CLOCK_MONOTONIC when the camera starts, then advance at the hardware
// clock's rate, which NTP never adjusts. Arrival times use that clock too, so both stay comparable when
// chronyd slews the system clock (as it does after boot).
inline uint64_t now_us() { return clock_us(CLOCK_MONOTONIC_RAW); }

inline void note(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  putchar('\n');
  fflush(stdout);
}

inline uint32_t parse_u32(const char *value, uint32_t fallback) {
  if (!value || !*value) return fallback;
  char *end = nullptr;
  unsigned long parsed = strtoul(value, &end, 10);
  return (end && *end == '\0') ? uint32_t(parsed) : fallback;
}

inline int parse_int(const std::string &value, int fallback) {
  if (value.empty()) return fallback;
  char *end = nullptr;
  long parsed = strtol(value.c_str(), &end, 10);
  return (end && *end == '\0') ? int(parsed) : fallback;
}

inline uint32_t env_u32(const char *name, uint32_t fallback) { return parse_u32(getenv(name), fallback); }

inline std::string env_str(const char *name, const char *fallback) {
  const char *value = getenv(name);
  return (value && *value) ? value : fallback;
}

// Reads KEY=value lines (no quoting); missing file -> empty map.
inline std::map<std::string, std::string> read_settings(const std::string &path) {
  std::map<std::string, std::string> out;
  FILE *f = fopen(path.c_str(), "r");
  if (!f) return out;
  char line[512];
  while (fgets(line, sizeof(line), f)) {
    std::string s(line);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
    size_t eq = s.find('=');
    if (eq == std::string::npos || s[0] == '#') continue;
    out[s.substr(0, eq)] = s.substr(eq + 1);
  }
  fclose(f);
  return out;
}
