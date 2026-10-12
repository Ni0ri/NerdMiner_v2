// Claude usage display - pure formatting helpers.
#ifdef CLAUDE_FEATURE // only compiled into boards with the Claude screen (saves RAM elsewhere)
#include "claudeFormat.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

static const char *MISSING = "-"; // built-in TFT fonts are ASCII only, so no en dash

// Formats value with one decimal and German comma ("1,2 M"); ",0" is dropped and values >= 100 are shown as integers.
static void formatOneDecimal(double value, const char *unit, char *buf, size_t bufsiz)
{
  if (value >= 99.95)
  {
    snprintf(buf, bufsiz, "%ld %s", (long)(value + 0.5), unit);
    return;
  }
  long tenths = (long)(value * 10.0 + 0.5);
  if (tenths % 10 == 0)
    snprintf(buf, bufsiz, "%ld %s", tenths / 10, unit);
  else
    snprintf(buf, bufsiz, "%ld,%ld %s", tenths / 10, tenths % 10, unit);
}

void claudeFormatTokens(int64_t tokens, char *buf, size_t bufsiz)
{
  if (bufsiz == 0) return;
  if (tokens < 0) { snprintf(buf, bufsiz, "%s", MISSING); return; }
  if (tokens < 1000) { snprintf(buf, bufsiz, "%ld", (long)tokens); return; }
  if (tokens < 999500LL) { formatOneDecimal(tokens / 1000.0, "k", buf, bufsiz); return; }
  if (tokens < 999500000LL) { formatOneDecimal(tokens / 1000000.0, "M", buf, bufsiz); return; }
  formatOneDecimal(tokens / 1000000000.0, "Mrd", buf, bufsiz);
}

void claudeFormatCost(float usd, char *buf, size_t bufsiz)
{
  if (bufsiz == 0) return;
  if (isnan(usd) || usd < 0) { snprintf(buf, bufsiz, "%s", MISSING); return; }
  long cents = (long)(usd * 100.0f + 0.5f);
  long whole = cents / 100;
  long frac = cents % 100;
  if (whole >= 1000)
    snprintf(buf, bufsiz, "%ld.%03ld,%02ld $", whole / 1000, whole % 1000, frac);
  else
    snprintf(buf, bufsiz, "%ld,%02ld $", whole, frac);
}

int claudeBudgetPercent(float monthCostUsd, float budgetUsd)
{
  if (isnan(monthCostUsd) || isnan(budgetUsd) || monthCostUsd < 0 || budgetUsd <= 0) return -1;
  float pct = monthCostUsd * 100.0f / budgetUsd;
  if (pct > 999.0f) pct = 999.0f;
  return (int)(pct + 0.5f);
}

void claudeFormatUpdated(const char *iso, char *buf, size_t bufsiz)
{
  if (bufsiz == 0) return;
  if (iso == NULL || iso[0] == '\0') { snprintf(buf, bufsiz, "%s", MISSING); return; }
  // Expected: YYYY-MM-DDTHH:MM...
  if (strlen(iso) >= 16 && iso[4] == '-' && iso[7] == '-' && (iso[10] == 'T' || iso[10] == ' ') && iso[13] == ':')
  {
    snprintf(buf, bufsiz, "%.2s.%.2s. %.5s", iso + 8, iso + 5, iso + 11);
    return;
  }
  snprintf(buf, bufsiz, "%.16s", iso);
}

void claudeFormatAge(uint32_t ageMinutes, char *buf, size_t bufsiz)
{
  if (bufsiz == 0) return;
  if (ageMinutes == 0) snprintf(buf, bufsiz, "gerade eben");
  else if (ageMinutes < 60) snprintf(buf, bufsiz, "vor %lu min", (unsigned long)ageMinutes);
  else if (ageMinutes < 48 * 60) snprintf(buf, bufsiz, "vor %lu h %lu min", (unsigned long)(ageMinutes / 60), (unsigned long)(ageMinutes % 60));
  else snprintf(buf, bufsiz, "vor %lu Tagen", (unsigned long)(ageMinutes / (24 * 60)));
}

bool claudeTokenMatches(const char *expected, const char *given)
{
  if (expected == NULL || expected[0] == '\0') return true;
  if (given == NULL) return false;
  size_t le = strlen(expected);
  size_t lg = strlen(given);
  unsigned char diff = (unsigned char)(le != lg);
  for (size_t i = 0; i < le; i++)
    diff |= (unsigned char)(expected[i] ^ (i < lg ? given[i] : 0));
  return diff == 0;
}

#endif // CLAUDE_FEATURE
