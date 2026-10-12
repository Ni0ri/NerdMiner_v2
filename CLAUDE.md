# CLAUDE.md – Regeln für diesen Fork

Fork von NerdMiner v2 mit Claude-Nutzungsanzeige für das ESP32-32E 3,5" (ST7796, 480×320, kein PSRAM).
Antworten, Doku und Hilfe-Texte auf **Deutsch**, Code-Bezeichner auf Englisch.

## Absolute Regeln
1. **Keine Secrets.** Keine API-Keys, Tokens, WLAN-Daten oder echten IP-Adressen im Repo.
   Beispiele nur mit `192.0.2.x` (TEST-NET). `bridge/config.json` und `*.dpapi` sind ignoriert.
2. **Mining hat Vorrang.** Im Firmware-Code kein `delay()` in Mining-Tasks, keine großen Heap-Allokationen,
   kein HTTPS/TLS für das Claude-Feature. Neuer Code nur im `loop()`- bzw. Monitor-Task. Ziel: > 40 KB Heap frei.
3. **Upstream-nah bleiben.** Änderungen an Upstream-Dateien klein halten und mit `#ifdef CLAUDE_FEATURE`
   bzw. `ESP32_32E_35` kapseln, damit Upstream-Updates gemergt werden können.
4. **Keine inoffiziellen APIs.** Claude-Daten nur über die offizielle Admin API oder ccusage; kein Scraping von claude.ai.

## Prüfen vor jedem Commit
- `test_host/run.sh` grün, `pio run -e ESP32-32E-35` baut ohne neue Warnungen.
- `Invoke-Pester bridge/tests` grün, `Invoke-ScriptAnalyzer -Path bridge -Recurse` ohne Fehler.
- PowerShell: Windows PowerShell 5.1 kompatibel (kein `??`, `?.`, ternärer Operator), `.ps1` als UTF-8 mit BOM und CRLF,
  Comment-based Help mit `.NOTES` (Autor Artur Warkentin, Version, Datum, Changelog), `-WhatIf` und `-SelfTest`.
