// Claude usage display - full-screen "Claude" page for 480x320 displays.
#ifdef CLAUDE_FEATURE

#include "claudeScreen.h"
#include "claudeFormat.h"
#include "claudeServer.h"

#include <Arduino.h>
#include <math.h>
#include <string.h>

#define CLS_W 480
#define CLS_H 320
#define CLS_BG TFT_BLACK
#define CLS_PANEL 0x18E3   // dark grey
#define CLS_LABEL 0xAD55   // light grey
#define CLS_ACCENT 0xDB27  // Claude-like orange
#define CLS_OK 0x2E86      // green
#define CLS_WARN 0xFE60    // yellow
#define CLS_BAD 0xF8A2     // red

static uint32_t s_lastReceived = 0;
static uint32_t s_lastAgeMin = 0xFFFFFFFF;
static int s_lastState = -1; // 0 = no data, 1 = fresh, 2 = stale

// Text inside a fixed box; padding clears the old value without flicker.
static void drawText(TFT_eSPI &tft, const char *text, int x, int y, int font, int size, uint16_t fg, uint16_t bg, int padWidth, uint8_t datum)
{
  tft.setTextDatum(datum);
  tft.setTextSize(size);
  tft.setTextColor(fg, bg);
  tft.setTextPadding(padWidth);
  tft.drawString(text, x, y, font);
  tft.setTextPadding(0);
  tft.setTextSize(1);
}

// Big value; falls back to normal size if it does not fit the box.
static void drawBigValue(TFT_eSPI &tft, const char *text, int x, int y, int boxWidth, uint16_t fg)
{
  tft.setTextSize(2);
  int size = (tft.textWidth(text, 4) <= boxWidth) ? 2 : 1;
  tft.setTextSize(1);
  tft.fillRect(x, y, boxWidth, 52, CLS_PANEL);
  drawText(tft, text, x, y + (size == 2 ? 0 : 13), 4, size, fg, CLS_PANEL, 0, TL_DATUM);
}

// Layout (480x320): header 0-34 | cost boxes 40-120 | tokens 126 | plan limits 146-220 |
// budget 226-258 | data state 266 | miner status bar 296-320
static void drawStatic(TFT_eSPI &tft)
{
  tft.fillScreen(CLS_BG);
  tft.fillRect(0, 0, CLS_W, 34, CLS_PANEL);
  drawText(tft, "Claude-Nutzung", 10, 5, 4, 1, CLS_ACCENT, CLS_PANEL, 0, TL_DATUM);
  tft.fillRoundRect(8, 40, 228, 80, 6, CLS_PANEL);
  tft.fillRoundRect(244, 40, 228, 80, 6, CLS_PANEL);
  drawText(tft, "Kosten heute", 18, 44, 2, 1, CLS_LABEL, CLS_PANEL, 0, TL_DATUM);
  drawText(tft, "Kosten Monat", 254, 44, 2, 1, CLS_LABEL, CLS_PANEL, 0, TL_DATUM);
  tft.fillRect(0, CLS_H - 24, CLS_W, 24, CLS_PANEL);
}

static void drawTokens(TFT_eSPI &tft, int x, const char *label, int64_t in, int64_t out)
{
  char a[16], b[16], line[48];
  claudeFormatTokens(in, a, sizeof(a));
  claudeFormatTokens(out, b, sizeof(b));
  snprintf(line, sizeof(line), "%s %s ein / %s aus", label, a, b);
  drawText(tft, line, x, 126, 2, 1, TFT_WHITE, CLS_BG, 226, TL_DATUM);
}

// Horizontal bar 0..100 % (clipped) with outline; colour by thresholds.
static void drawBar(TFT_eSPI &tft, int y, int pct, int warnFrom, int badFrom)
{
  int inner = CLS_W - 24;
  int fill = (pct >= 100) ? inner : (pct <= 0 ? 0 : inner * pct / 100);
  uint16_t color = pct < warnFrom ? CLS_OK : (pct < badFrom ? CLS_WARN : CLS_BAD);
  tft.drawRect(10, y, CLS_W - 20, 16, CLS_LABEL);
  tft.fillRect(12, y + 2, inner, 12, CLS_BG);
  if (fill > 0) tft.fillRect(12, y + 2, fill, 12, color);
}

static void drawLimitRow(TFT_eSPI &tft, int y, const char *name, float pct, const char *resets)
{
  char line[64];
  if (isnan(pct))
  {
    snprintf(line, sizeof(line), "%s: -", name);
    drawText(tft, line, 10, y, 2, 1, CLS_LABEL, CLS_BG, 300, TL_DATUM);
    tft.drawRect(10, y + 18, CLS_W - 20, 16, CLS_LABEL);
    tft.fillRect(12, y + 20, CLS_W - 24, 12, CLS_BG);
    return;
  }
  int p = (int)(pct + 0.5f);
  if (resets[0] != '\0')
    snprintf(line, sizeof(line), "%s: %d %%   Reset %s", name, p, resets);
  else
    snprintf(line, sizeof(line), "%s: %d %%", name, p);
  drawText(tft, line, 10, y, 2, 1, TFT_WHITE, CLS_BG, 300, TL_DATUM);
  drawBar(tft, y + 18, p, 75, 90);
}

static void drawLimits(TFT_eSPI &tft, const ClaudeUsage &u)
{
  const int y = 146;
  tft.fillRect(0, y, CLS_W, 76, CLS_BG);
  if (isnan(u.sessionPct) && isnan(u.weekPct))
  {
    drawText(tft, "Abo-Limits: keine Daten", 10, y, 2, 1, CLS_LABEL, CLS_BG, 0, TL_DATUM);
    drawText(tft, "Claude-Code-Statuszeile einrichten (siehe README)", 10, y + 20, 2, 1, CLS_LABEL, CLS_BG, 0, TL_DATUM);
    return;
  }
  drawLimitRow(tft, y, "Abo Sitzung (5 h)", u.sessionPct, u.sessionResets);
  drawLimitRow(tft, y + 38, "Abo Woche", u.weekPct, u.weekResets);
  if (u.limitsAgeMin >= 0)
  {
    char age[24];
    claudeFormatAge((uint32_t)u.limitsAgeMin, age, sizeof(age));
    drawText(tft, age, CLS_W - 10, y, 2, 1, u.limitsAgeMin > 360 ? CLS_WARN : CLS_LABEL, CLS_BG, 0, TR_DATUM);
  }
}

static void drawBudget(TFT_eSPI &tft, const ClaudeUsage &u)
{
  const int y = 226;
  char cost[20], budget[20], line[72];
  int pct = claudeBudgetPercent(u.monthCost, u.budget);
  tft.fillRect(0, y, CLS_W, 34, CLS_BG);
  if (pct < 0)
  {
    drawText(tft, "Budget: -", 10, y, 2, 1, CLS_LABEL, CLS_BG, 0, TL_DATUM);
    tft.drawRect(10, y + 18, CLS_W - 20, 16, CLS_LABEL);
    return;
  }
  claudeFormatCost(u.monthCost, cost, sizeof(cost));
  claudeFormatCost(u.budget, budget, sizeof(budget));
  snprintf(line, sizeof(line), "Monat vs. Budget: %s von %s (%d %%)", cost, budget, pct);
  drawText(tft, line, 10, y, 2, 1, CLS_LABEL, CLS_BG, 0, TL_DATUM);
  drawBar(tft, y + 18, pct, 75, 100);
}

static void drawSourceLabel(TFT_eSPI &tft, const ClaudeUsage &u)
{
  const char *label = "";
  if (strcmp(u.source, "admin_api") == 0) label = "Admin API (echte Kosten)";
  else if (strcmp(u.source, "ccusage") == 0) label = "ccusage: API-Preis, kein Abo";
  else if (strcmp(u.source, "test") == 0) label = "TESTDATEN";
  else label = u.source;
  drawText(tft, label, CLS_W - 10, 10, 2, 1, CLS_LABEL, CLS_PANEL, 220, TR_DATUM);
}

static void drawValues(TFT_eSPI &tft, const ClaudeUsage &u, int state, uint32_t ageMin)
{
  char buf[64], when[24], age[24];
  drawSourceLabel(tft, u);
  claudeFormatCost(u.todayCost, buf, sizeof(buf));
  drawBigValue(tft, buf, 18, 62, 208, TFT_WHITE);
  claudeFormatCost(u.monthCost, buf, sizeof(buf));
  drawBigValue(tft, buf, 254, 62, 208, TFT_WHITE);
  drawTokens(tft, 10, "Heute", u.todayIn, u.todayOut);
  drawTokens(tft, 246, "Monat", u.monthIn, u.monthOut);
  drawLimits(tft, u);
  drawBudget(tft, u);

  const int y = 266;
  tft.fillRect(0, y, CLS_W, 28, CLS_BG);
  if (state == 0)
  {
    drawText(tft, "Keine Daten - Bridge auf dem PC aktiv?", 10, y, 4, 1, CLS_WARN, CLS_BG, CLS_W - 20, TL_DATUM);
    return;
  }
  claudeFormatUpdated(u.updated, when, sizeof(when));
  claudeFormatAge(ageMin, age, sizeof(age));
  if (state == 2)
    snprintf(buf, sizeof(buf), "Daten veraltet! Stand %s (%s)", when, age);
  else
    snprintf(buf, sizeof(buf), "Stand %s (%s)", when, age);
  drawText(tft, buf, 10, y + 4, 2, 1, state == 2 ? CLS_BAD : CLS_LABEL, CLS_BG, CLS_W - 20, TL_DATUM);
}

void claudeDrawScreen(TFT_eSPI &tft, bool fullRedraw, const char *hashRateKHs, const char *bestDiff, const char *temperature)
{
  ClaudeUsage u;
  claudeGetSnapshot(u);
  uint32_t ageMs = u.valid ? (millis() - u.receivedMs) : 0;
  uint32_t ageMin = ageMs / 60000UL;
  int state = !u.valid ? 0 : (ageMs > CLAUDE_STALE_MS ? 2 : 1);

  if (fullRedraw) drawStatic(tft);
  if (fullRedraw || state != s_lastState || u.receivedMs != s_lastReceived || ageMin != s_lastAgeMin)
  {
    drawValues(tft, u, state, ageMin);
    s_lastState = state;
    s_lastReceived = u.receivedMs;
    s_lastAgeMin = ageMin;
  }

  char line[96];
  snprintf(line, sizeof(line), "Miner: %s kH/s   Best Diff: %s   %s C", hashRateKHs, bestDiff, temperature);
  drawText(tft, line, 10, CLS_H - 12, 2, 1, TFT_WHITE, CLS_PANEL, CLS_W - 20, ML_DATUM);
}

#endif // CLAUDE_FEATURE
