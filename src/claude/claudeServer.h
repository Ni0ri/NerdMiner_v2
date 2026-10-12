// Claude usage display - LAN endpoint POST/GET /claude and thread-safe access to the last data.
#ifndef CLAUDE_SERVER_H_
#define CLAUDE_SERVER_H_

#include "claudeUsage.h"

// Data older than this is shown as "Daten veraltet".
#define CLAUDE_STALE_MS (30UL * 60UL * 1000UL)

// Call regularly from loop() (NOT from mining tasks). Starts the web server once WiFi is up,
// handles at most one pending request per call and logs the heap every 60 s.
void claudeServerLoop(void);

// Copies the last received data (thread-safe, no heap). Returns snapshot.valid.
bool claudeGetSnapshot(ClaudeUsage &out);

#endif // CLAUDE_SERVER_H_
