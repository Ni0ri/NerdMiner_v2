// Claude usage display - data model and JSON (de)serialisation.
// No Arduino dependency apart from ArduinoJson, so it can be unit-tested on the host.
#ifndef CLAUDE_USAGE_H_
#define CLAUDE_USAGE_H_

#include <stddef.h>
#include <stdint.h>

// Maximum accepted body size for POST /claude.
#define CLAUDE_MAX_BODY 1024

// Fixed-size snapshot (no heap) of the last data received from the bridge.
// Missing values: tokens = CLAUDE_MISSING_TOKENS (-1), costs/budget = NAN, strings = "".
struct ClaudeUsage
{
  bool valid;           // true once a valid POST was received since boot
  uint32_t receivedMs;  // millis() at reception
  char source[16];      // "admin_api", "ccusage", "test", ...
  char updated[32];     // ISO 8601 timestamp from the bridge
  int64_t todayIn;
  int64_t todayOut;
  float todayCost;
  int64_t monthIn;
  int64_t monthOut;
  float monthCost;
  float budget;
  // claude.ai plan limits (Pro/Max) from the Claude Code status line; NAN / "" / -1 = missing
  float sessionPct;        // 5-hour window, 0..100
  char sessionResets[16];  // already formatted by the bridge, e.g. "19:10"
  float weekPct;           // 7-day window, 0..100
  char weekResets[16];     // e.g. "Fr 00:00"
  int32_t limitsAgeMin;    // age of the limit values in minutes, -1 = unknown
};

// Resets all fields to "missing" and valid = false.
void claudeUsageClear(ClaudeUsage &u);

// Parses the bridge JSON. Unknown fields are ignored, wrong types count as missing.
// Returns false for invalid JSON, a non-object root or a body larger than CLAUDE_MAX_BODY.
// On success valid is set to true; receivedMs is left to the caller.
bool claudeUsageParse(const char *json, size_t len, ClaudeUsage &out);

// Serialises the snapshot for GET /claude (missing values as null). ageSeconds < 0 -> "age_s": null.
// Returns the number of bytes written (0 on overflow).
size_t claudeUsageToJson(const ClaudeUsage &u, long ageSeconds, char *buf, size_t bufsiz);

#endif // CLAUDE_USAGE_H_
