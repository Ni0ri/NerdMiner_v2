// Claude usage display - full-screen "Claude" page for 480x320 displays.
#ifndef CLAUDE_SCREEN_H_
#define CLAUDE_SCREEN_H_

#include <TFT_eSPI.h>

// Draws the Claude page. fullRedraw = screen was just switched to this page.
// Values are only repainted when data, age or stale state change; the miner status line every call.
// Uses built-in TFT fonts with background colour only (no sprites -> no heap allocation).
void claudeDrawScreen(TFT_eSPI &tft, bool fullRedraw, const char *hashRateKHs, const char *bestDiff, const char *temperature);

#endif // CLAUDE_SCREEN_H_
