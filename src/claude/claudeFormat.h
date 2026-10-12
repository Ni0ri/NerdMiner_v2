// Claude usage display - pure formatting helpers (no Arduino dependency, unit-testable on the host).
#ifndef CLAUDE_FORMAT_H_
#define CLAUDE_FORMAT_H_

#include <stddef.h>
#include <stdint.h>

// Marker for "value missing" in integer token fields.
#define CLAUDE_MISSING_TOKENS (-1LL)

// Tokens compact in German notation: 950 -> "950", 45000 -> "45 k", 1234567 -> "1,2 M", 2.5e9 -> "2,5 Mrd".
// Missing (< 0) -> "-".
void claudeFormatTokens(int64_t tokens, char *buf, size_t bufsiz);

// Cost in USD with German decimal comma: 1.84 -> "1,84 $", 1234.5 -> "1.234,50 $". NaN/negative -> "-".
void claudeFormatCost(float usd, char *buf, size_t bufsiz);

// Percentage of budget used (0..999), -1 if not computable (missing cost or budget <= 0).
int claudeBudgetPercent(float monthCostUsd, float budgetUsd);

// "2026-10-12T12:55:00+02:00" -> "12.10. 12:55". Unknown format -> copies up to 16 chars, empty -> "-".
void claudeFormatUpdated(const char *iso, char *buf, size_t bufsiz);

// Age in minutes as text: 0 -> "gerade eben", 7 -> "vor 7 min", 135 -> "vor 2 h 15 min".
void claudeFormatAge(uint32_t ageMinutes, char *buf, size_t bufsiz);

// Constant-time-ish string compare for the X-Token header. Empty expected token = no protection (always true).
bool claudeTokenMatches(const char *expected, const char *given);

#endif // CLAUDE_FORMAT_H_
