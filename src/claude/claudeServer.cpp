// Claude usage display - LAN endpoint POST/GET /claude.
// Runs in the Arduino loop task; the mining tasks are never touched. No TLS, no API keys on the ESP:
// the PC bridge sends ready-made numbers.
#ifdef CLAUDE_FEATURE

#include "claudeServer.h"
#include "claudeFormat.h"

#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>

#include "../drivers/storage/storage.h"

extern TSettings Settings;

static WebServer s_server(80);
static bool s_started = false;
static uint32_t s_lastHeapLog = 0;

static ClaudeUsage s_usage;
static bool s_usageInit = false;
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;

bool claudeGetSnapshot(ClaudeUsage &out)
{
  portENTER_CRITICAL(&s_mux);
  if (!s_usageInit)
  {
    claudeUsageClear(s_usage);
    s_usageInit = true;
  }
  out = s_usage;
  portEXIT_CRITICAL(&s_mux);
  return out.valid;
}

static void storeUsage(const ClaudeUsage &u)
{
  portENTER_CRITICAL(&s_mux);
  s_usage = u;
  s_usageInit = true;
  portEXIT_CRITICAL(&s_mux);
}

static void sendJson(int code, const char *body)
{
  s_server.sendHeader("Cache-Control", "no-store");
  s_server.send(code, "application/json", body);
}

static bool checkToken(void)
{
  if (claudeTokenMatches(Settings.ClaudeToken, s_server.header("X-Token").c_str())) return true;
  Serial.println("[CLAUDE] Anfrage abgelehnt: X-Token fehlt oder falsch");
  sendJson(401, "{\"ok\":false,\"error\":\"invalid token\"}");
  return false;
}

static void handlePost(void)
{
  if (!checkToken()) return;
  if (!s_server.hasArg("plain"))
  {
    sendJson(400, "{\"ok\":false,\"error\":\"empty body\"}");
    return;
  }
  const String &body = s_server.arg("plain");
  if (body.length() > CLAUDE_MAX_BODY)
  {
    sendJson(413, "{\"ok\":false,\"error\":\"body too large\"}");
    return;
  }
  ClaudeUsage u;
  if (!claudeUsageParse(body.c_str(), body.length(), u))
  {
    Serial.printf("[CLAUDE] Ungueltiges JSON (%u Bytes)\n", (unsigned)body.length());
    sendJson(400, "{\"ok\":false,\"error\":\"invalid json\"}");
    return;
  }
  u.receivedMs = millis();
  storeUsage(u);
  sendJson(200, "{\"ok\":true}");
  Serial.printf("[CLAUDE] Daten empfangen: Quelle=%s, %u Bytes, Heap frei=%u\n", u.source, (unsigned)body.length(), ESP.getFreeHeap());
}

static void handleGet(void)
{
  if (!checkToken()) return;
  ClaudeUsage u;
  claudeGetSnapshot(u);
  long age = u.valid ? (long)((millis() - u.receivedMs) / 1000UL) : -1;
  static char buf[768];
  if (claudeUsageToJson(u, age, buf, sizeof(buf)) == 0)
  {
    sendJson(500, "{\"ok\":false,\"error\":\"buffer\"}");
    return;
  }
  sendJson(200, buf);
}

void claudeServerLoop(void)
{
  uint32_t now = millis();
  if (now - s_lastHeapLog >= 60000UL || s_lastHeapLog == 0)
  {
    s_lastHeapLog = now ? now : 1;
    Serial.printf("[CLAUDE] Heap frei=%u, min. frei=%u, groesster Block=%u\n",
                  ESP.getFreeHeap(), ESP.getMinFreeHeap(), ESP.getMaxAllocHeap());
  }

  if (WiFi.status() != WL_CONNECTED) return;
  if (!s_started)
  {
    static const char *headerKeys[] = {"X-Token"};
    s_server.collectHeaders(headerKeys, 1);
    s_server.on("/claude", HTTP_POST, handlePost);
    s_server.on("/claude", HTTP_GET, handleGet);
    s_server.onNotFound([]() { sendJson(404, "{\"ok\":false,\"error\":\"not found\"}"); });
    s_server.begin();
    s_started = true;
    Serial.printf("[CLAUDE] Endpoint bereit: http://%s/claude\n", WiFi.localIP().toString().c_str());
  }
  s_server.handleClient();
}

#endif // CLAUDE_FEATURE
