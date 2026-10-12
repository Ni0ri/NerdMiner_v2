// Claude usage display - data model and JSON (de)serialisation.
#ifdef CLAUDE_FEATURE // only compiled into boards with the Claude screen (saves RAM elsewhere)
#include "claudeUsage.h"
#include "claudeFormat.h"

#include <ArduinoJson.h>
#include <math.h>
#include <string.h>

// Static documents: no heap allocation per request and no large stack frames.
static StaticJsonDocument<768> s_filter;
static StaticJsonDocument<1536> s_doc;

void claudeUsageClear(ClaudeUsage &u)
{
  memset(&u, 0, sizeof(u));
  u.valid = false;
  u.todayIn = u.todayOut = u.monthIn = u.monthOut = CLAUDE_MISSING_TOKENS;
  u.todayCost = u.monthCost = u.budget = NAN;
  u.sessionPct = u.weekPct = NAN;
  u.limitsAgeMin = -1;
}

static float readPercent(JsonVariantConst v)
{
  if (!v.is<double>()) return NAN;
  double d = v.as<double>();
  if (isnan(d) || d < 0) return NAN;
  if (d > 999) d = 999;
  return (float)d;
}

static int64_t readTokens(JsonVariantConst v)
{
  if (!v.is<double>() && !v.is<long long>()) return CLAUDE_MISSING_TOKENS;
  double d = v.as<double>();
  if (isnan(d) || d < 0 || d > 9.0e15) return CLAUDE_MISSING_TOKENS;
  return (int64_t)(d + 0.5);
}

static float readCost(JsonVariantConst v)
{
  if (!v.is<double>()) return NAN;
  double d = v.as<double>();
  if (isnan(d) || d < 0) return NAN;
  return (float)d;
}

static void readString(JsonVariantConst v, char *dst, size_t dstsiz)
{
  dst[0] = '\0';
  const char *s = v.as<const char *>();
  if (s == NULL) return;
  strncpy(dst, s, dstsiz - 1);
  dst[dstsiz - 1] = '\0';
}

static void readPeriod(JsonVariantConst p, int64_t &in, int64_t &outTok, float &cost)
{
  in = readTokens(p["input_tokens"]);
  outTok = readTokens(p["output_tokens"]);
  cost = readCost(p["cost_usd"]);
}

bool claudeUsageParse(const char *json, size_t len, ClaudeUsage &out)
{
  if (json == NULL || len == 0 || len > CLAUDE_MAX_BODY) return false;

  if (s_filter.isNull())
  {
    // Built once; overflow would silently drop fields, so it is sized with headroom (also for 64-bit host tests).
    s_filter["source"] = true;
    s_filter["updated"] = true;
    s_filter["budget_usd"] = true;
    for (const char *period : {"today", "month"})
    {
      s_filter[period]["input_tokens"] = true;
      s_filter[period]["output_tokens"] = true;
      s_filter[period]["cost_usd"] = true;
    }
    for (const char *window : {"session", "week"})
    {
      s_filter["limits"][window]["used_pct"] = true;
      s_filter["limits"][window]["resets"] = true;
    }
    s_filter["limits"]["age_min"] = true;
  }

  s_doc.clear();
  DeserializationError err = deserializeJson(s_doc, json, len, DeserializationOption::Filter(s_filter));
  if (err || s_filter.overflowed() || !s_doc.is<JsonObject>()) return false;

  ClaudeUsage u;
  claudeUsageClear(u);
  JsonVariantConst root = s_doc.as<JsonVariantConst>();
  readString(root["source"], u.source, sizeof(u.source));
  readString(root["updated"], u.updated, sizeof(u.updated));
  readPeriod(root["today"], u.todayIn, u.todayOut, u.todayCost);
  readPeriod(root["month"], u.monthIn, u.monthOut, u.monthCost);
  u.budget = readCost(root["budget_usd"]);
  JsonVariantConst limits = root["limits"];
  u.sessionPct = readPercent(limits["session"]["used_pct"]);
  readString(limits["session"]["resets"], u.sessionResets, sizeof(u.sessionResets));
  u.weekPct = readPercent(limits["week"]["used_pct"]);
  readString(limits["week"]["resets"], u.weekResets, sizeof(u.weekResets));
  if (limits["age_min"].is<long>() && limits["age_min"].as<long>() >= 0)
    u.limitsAgeMin = (int32_t)limits["age_min"].as<long>();
  u.valid = true;
  out = u;
  return true;
}

static void writeTokens(JsonObject o, const char *key, int64_t v)
{
  if (v < 0) o[key] = nullptr;
  else o[key] = (long long)v;
}

static void writeCost(JsonObject o, const char *key, float v)
{
  if (isnan(v)) o[key] = nullptr;
  else o[key] = round((double)v * 100.0) / 100.0;
}

size_t claudeUsageToJson(const ClaudeUsage &u, long ageSeconds, char *buf, size_t bufsiz)
{
  s_doc.clear();
  JsonObject root = s_doc.to<JsonObject>();
  root["received"] = u.valid;
  if (ageSeconds < 0) root["age_s"] = nullptr;
  else root["age_s"] = ageSeconds;
  root["source"] = (const char *)u.source;
  root["updated"] = (const char *)u.updated;
  JsonObject today = root.createNestedObject("today");
  writeTokens(today, "input_tokens", u.todayIn);
  writeTokens(today, "output_tokens", u.todayOut);
  writeCost(today, "cost_usd", u.todayCost);
  JsonObject month = root.createNestedObject("month");
  writeTokens(month, "input_tokens", u.monthIn);
  writeTokens(month, "output_tokens", u.monthOut);
  writeCost(month, "cost_usd", u.monthCost);
  writeCost(root, "budget_usd", u.budget);
  JsonObject limits = root.createNestedObject("limits");
  JsonObject session = limits.createNestedObject("session");
  writeCost(session, "used_pct", u.sessionPct);
  session["resets"] = (const char *)u.sessionResets;
  JsonObject week = limits.createNestedObject("week");
  writeCost(week, "used_pct", u.weekPct);
  week["resets"] = (const char *)u.weekResets;
  if (u.limitsAgeMin < 0) limits["age_min"] = nullptr;
  else limits["age_min"] = u.limitsAgeMin;
  if (s_doc.overflowed()) return 0;
  size_t n = serializeJson(s_doc, buf, bufsiz);
  return (n + 1 >= bufsiz) ? 0 : n;
}

#endif // CLAUDE_FEATURE
