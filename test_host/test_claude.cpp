// Host unit tests for the pure Claude display helpers (no hardware needed).
// Build/run: test_host/run.sh (needs g++ and git; fetches ArduinoJson v6.21.5)
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "claudeFormat.h"
#include "claudeUsage.h"

static int s_total = 0;
static int s_ok = 0;

static void check(bool cond, const char *name)
{
  s_total++;
  if (cond) s_ok++;
  printf("%s %s\n", cond ? "[OK]  " : "[FAIL]", name);
}

static bool tokensAre(long long v, const char *expected)
{
  char buf[24];
  claudeFormatTokens(v, buf, sizeof(buf));
  if (strcmp(buf, expected) != 0) printf("       tokens %lld -> '%s' (erwartet '%s')\n", v, buf, expected);
  return strcmp(buf, expected) == 0;
}

static bool costIs(float v, const char *expected)
{
  char buf[24];
  claudeFormatCost(v, buf, sizeof(buf));
  if (strcmp(buf, expected) != 0) printf("       cost %f -> '%s' (erwartet '%s')\n", v, buf, expected);
  return strcmp(buf, expected) == 0;
}

int main()
{
  check(tokensAre(-1, "-"), "Tokens fehlend -> '-'");
  check(tokensAre(0, "0") && tokensAre(950, "950"), "Tokens < 1000 als Zahl");
  check(tokensAre(45000, "45 k") && tokensAre(1500, "1,5 k") && tokensAre(99949, "99,9 k"), "Tokens in k");
  check(tokensAre(120000, "120 k") && tokensAre(999499, "999 k") && tokensAre(999500, "1 M"), "Tokens k/M-Grenze");
  check(tokensAre(1234567, "1,2 M") && tokensAre(3100000, "3,1 M") && tokensAre(980000, "980 k"), "Tokens in M");
  check(tokensAre(2500000000LL, "2,5 Mrd"), "Tokens in Mrd");

  check(costIs(1.84f, "1,84 $") && costIs(41.2f, "41,20 $") && costIs(0.0f, "0,00 $"), "Kosten mit Komma");
  check(costIs(1234.5f, "1.234,50 $"), "Kosten mit Tausenderpunkt");
  check(costIs(NAN, "-") && costIs(-1.0f, "-"), "Kosten fehlend -> '-'");

  check(claudeBudgetPercent(41.2f, 100.0f) == 41, "Budget 41 %");
  check(claudeBudgetPercent(150.0f, 100.0f) == 150, "Budget ueber 100 %");
  check(claudeBudgetPercent(NAN, 100.0f) == -1 && claudeBudgetPercent(10.0f, 0.0f) == -1 && claudeBudgetPercent(1.0f, NAN) == -1, "Budget nicht berechenbar");

  char buf[40];
  claudeFormatUpdated("2026-10-12T12:55:00+02:00", buf, sizeof(buf));
  check(strcmp(buf, "12.10. 12:55") == 0, "Zeitstempel kompakt");
  claudeFormatUpdated("", buf, sizeof(buf));
  check(strcmp(buf, "-") == 0, "Zeitstempel leer");
  claudeFormatUpdated("gestern", buf, sizeof(buf));
  check(strcmp(buf, "gestern") == 0, "Zeitstempel unbekanntes Format unveraendert");

  claudeFormatAge(0, buf, sizeof(buf));
  bool a0 = strcmp(buf, "gerade eben") == 0;
  claudeFormatAge(7, buf, sizeof(buf));
  bool a7 = strcmp(buf, "vor 7 min") == 0;
  claudeFormatAge(135, buf, sizeof(buf));
  check(a0 && a7 && strcmp(buf, "vor 2 h 15 min") == 0, "Alter in Worten");

  check(claudeTokenMatches("", NULL) && claudeTokenMatches(NULL, "x"), "Ohne Token kein Schutz");
  check(claudeTokenMatches("abc123", "abc123"), "Token passt");
  check(!claudeTokenMatches("abc123", "abc12") && !claudeTokenMatches("abc123", "abc1234") && !claudeTokenMatches("abc123", NULL), "Token passt nicht");

  ClaudeUsage u;
  const char *full = "{\"source\":\"admin_api\",\"updated\":\"2026-10-12T12:55:00+02:00\","
                     "\"today\":{\"input_tokens\":120000,\"output_tokens\":45000,\"cost_usd\":1.84},"
                     "\"month\":{\"input_tokens\":3100000,\"output_tokens\":980000,\"cost_usd\":41.20},"
                     "\"budget_usd\":100.0,\"extra\":{\"ignored\":[1,2,3]}}";
  bool ok = claudeUsageParse(full, strlen(full), u);
  check(ok && u.valid && strcmp(u.source, "admin_api") == 0 && u.todayIn == 120000 && u.todayOut == 45000 &&
            fabsf(u.todayCost - 1.84f) < 0.001f && u.monthIn == 3100000 && u.monthOut == 980000 &&
            fabsf(u.monthCost - 41.2f) < 0.001f && fabsf(u.budget - 100.0f) < 0.001f,
        "Vollstaendiges JSON wird gelesen");

  const char *partial = "{\"today\":{\"cost_usd\":2}}";
  ok = claudeUsageParse(partial, strlen(partial), u);
  check(ok && u.todayIn == CLAUDE_MISSING_TOKENS && fabsf(u.todayCost - 2.0f) < 0.001f && isnan(u.monthCost) && isnan(u.budget) &&
            u.source[0] == '\0',
        "Fehlende Felder bleiben leer");

  const char *wrongTypes = "{\"today\":{\"input_tokens\":\"viel\",\"cost_usd\":-3},\"budget_usd\":\"x\"}";
  ok = claudeUsageParse(wrongTypes, strlen(wrongTypes), u);
  check(ok && u.todayIn == CLAUDE_MISSING_TOKENS && isnan(u.todayCost) && isnan(u.budget), "Falsche Typen gelten als fehlend");

  const char *bad1 = "{\"today\":";
  const char *bad2 = "[1,2]";
  check(!claudeUsageParse(bad1, strlen(bad1), u) && !claudeUsageParse(bad2, strlen(bad2), u) && !claudeUsageParse("", 0, u),
        "Ungueltiges JSON wird abgelehnt");

  static char big[CLAUDE_MAX_BODY + 50];
  memset(big, ' ', sizeof(big));
  big[0] = '{';
  big[sizeof(big) - 2] = '}';
  big[sizeof(big) - 1] = '\0';
  check(!claudeUsageParse(big, strlen(big), u), "Zu grosser Body wird abgelehnt");

  const char *longSource = "{\"source\":\"abcdefghijklmnopqrstuvwxyz0123456789\"}";
  ok = claudeUsageParse(longSource, strlen(longSource), u);
  check(ok && strlen(u.source) == sizeof(u.source) - 1, "Zu langer Text wird gekuerzt");

  char out[512];
  claudeUsageParse(full, strlen(full), u);
  size_t n = claudeUsageToJson(u, 42, out, sizeof(out));
  printf("       GET: %s\n", out);
  check(n > 0 && strstr(out, "\"received\":true") && strstr(out, "\"age_s\":42") && strstr(out, "\"input_tokens\":3100000") &&
            strstr(out, "\"cost_usd\":1.84") && strstr(out, "\"budget_usd\":100"),
        "GET-JSON enthaelt die Werte");

  claudeUsageClear(u);
  n = claudeUsageToJson(u, -1, out, sizeof(out));
  printf("       GET leer: %s\n", out);
  check(n > 0 && strstr(out, "\"received\":false") && strstr(out, "\"age_s\":null") && strstr(out, "\"cost_usd\":null"),
        "GET-JSON ohne Daten");

  char tiny[16];
  claudeUsageParse(full, strlen(full), u);
  check(claudeUsageToJson(u, 1, tiny, sizeof(tiny)) == 0, "GET-JSON Pufferueberlauf erkannt");

  printf("%d/%d Tests gruen\n", s_ok, s_total);
  return s_ok == s_total ? 0 : 1;
}
