// Claude usage display - full-screen "Claude" page for 480x320 displays.
#ifdef CLAUDE_FEATURE

#include "claudeScreen.h"
#include "claudeFormat.h"
#include "claudeServer.h"

#include <Arduino.h>
#include <string.h>

#define CS_W 480
#define CS_H 320
#define CS_BG TFT_BLACK
#define CS_PANEL 0x18E3   // dark grey
#define CS_LABEL 0xAD55   // light grey
#define CS_ACCENT 0xDB27  // Claude-like orange
#define CS_OK 0x2E86      // green
#define CS_WARN 0xFE60    // yellow
#define CS_BAD 0xF8A2     // red

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
  tft.fillRect(x, y, boxWidth, 52, CS_PANEL);
  drawText(tft, text, x, y + (size == 2 ? 0 : 13), 4, size, fg, CS_PANEL, 0, TL_DATUM);
}

static void drawStatic(TFT_eSPI &tft)
{
  tft.fillScreen(CS_BG);
  tft.fillRect(0, 0, CS_W, 36, CS_PANEL);
  drawText(tft, "Claude-Nutzung", 10, 6, 4, 1, CS_ACCENT, CS_PANEL, 0, TL_DATUM);
  tft.fillRoundRect(8, 44, 228, 96, 6, CS_PANEL);
  tft.fillRoundRect(244, 44, 228, 96, 6, CS_PANEL);
  drawText(tft, "Kosten heute", 18, 50, 2, 1, CS_LABEL, CS_PANEL, 0, TL_DATUM);
  drawText(tft, "Kosten Monat", 254, 50, 2, 1, CS_LABEL, CS_PANEL, 0, TL_DATUM);
  drawText(tft, "Tokens heute", 10, 150, 2, 1, CS_LABEL, CS_BG, 0, TL_DATUM);
  drawText(tft, "Tokens Monat", 246, 150, 2, 1, CS_LABEL, CS_BG, 0, TL_DATUM);
  tft.fillRect(0, CS_H - 24, CS_W, 24, CS_PANEL);
}

static void drawTokens(TFT_eSPI &tft, int x, int64_t in, int64_t out)
{
  char a[16], b[16], line[48];
  claudeFormatTokens(in, a, sizeof(a));
  claudeFormatTokens(out, b, sizeof(b));
  snprintf(line, sizeof(line), "%s ein / %s aus", a, b);
  drawText(tft, line, x, 168, 4, 1, TFT_WHITE, CS_BG, 226, TL_DATUM);
}

static void drawBudget(TFT_eSPI &tft, const ClaudeUsage &u)
{
  const int y = 204;
  char cost[20], budget[20], line[72];
  int pct = claudeBudgetPercent(u.monthCost, u.budget);
  tft.fillRect(0, y, CS_W, 44, CS_BG);
  if (pct < 0)
  {
    drawText(tft, "Budget: -", 10, y, 2, 1, CS_LABEL, CS_BG, 0, TL_DATUM);
    tft.drawRect(10, y + 20, CS_W - 20, 20, CS_LABEL);
    return;
  }
  claudeFormatCost(u.monthCost, cost, sizeof(cost));
  claudeFormatCost(u.budget, budget, sizeof(budget));
  snprintf(line, sizeof(line), "Monat vs. Budget: %s von %s (%d %%)", cost, budget, pct);
  drawText(tft, line, 10, y, 2, 1, CS_LABEL, CS_BG, 0, TL_DATUM);
  uint16_t color = pct < 75 ? CS_OK : (pct < 100 ? CS_WARN : CS_BAD);
  int inner = CS_W - 24;
  int fill = (pct >= 100) ? inner : inner * pct / 100;
  tft.drawRect(10, y + 20, CS_W - 20, 20, CS_LABEL);
  tft.fillRect(12, y + 22, fill, 16, color);
}

static void drawSourceLabel(TFT_eSPI &tft, const ClaudeUsage &u)
{
  const char *label = "";
  if (strcmp(u.source, "admin_api") == 0) label = "Admin API (echte Kosten)";
  else if (strcmp(u.source, "ccusage") == 0) label = "ccusage: API-Preis, kein Abo";
  else if (strcmp(u.source, "test") == 0) label = "TESTDATEN";
  else label = u.source;
  drawText(tft, label, CS_W - 10, 12, 2, 1, CS_LABEL, CS_PANEL, 220, TR_DATUM);
}

static void drawValues(TFT_eSPI &tft, const ClaudeUsage &u, int state, uint32_t ageMin)
{
  char buf[64], when[24], age[24];
  drawSourceLabel(tft, u);
  claudeFormatCost(u.todayCost, buf, sizeof(buf));
  drawBigValue(tft, buf, 18, 76, 208, TFT_WHITE);
  claudeFormatCost(u.monthCost, buf, sizeof(buf));
  drawBigValue(tft, buf, 254, 76, 208, TFT_WHITE);
  drawTokens(tft, 10, u.todayIn, u.todayOut);
  drawTokens(tft, 246, u.monthIn, u.monthOut);
  drawBudget(tft, u);

  const int y = 256;
  if (state == 0)
  {
    drawText(tft, "Keine Daten - Bridge auf dem PC aktiv?", 10, y, 4, 1, CS_WARN, CS_BG, CS_W - 20, TL_DATUM);
    return;
  }
  claudeFormatUpdated(u.updated, when, sizeof(when));
  claudeFormatAge(ageMin, age, sizeof(age));
  if (state == 2)
    snprintf(buf, sizeof(buf), "Daten veraltet! Stand %s (%s)", when, age);
  else
    snprintf(buf, sizeof(buf), "Stand %s (%s)", when, age);
  drawText(tft, buf, 10, y, 4, 1, state == 2 ? CS_BAD : CS_LABEL, CS_BG, CS_W - 20, TL_DATUM);
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
  drawText(tft, line, 10, CS_H - 12, 2, 1, TFT_WHITE, CS_PANEL, CS_W - 20, ML_DATUM);
}

#endif // CLAUDE_FEATURE
