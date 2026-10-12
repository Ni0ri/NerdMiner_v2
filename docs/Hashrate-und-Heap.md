# Hashrate- und Heap-Vergleich

Ziel laut Abnahme: Hashrate höchstens ~5 % unter dem Ausgangswert, freier Heap im Betrieb weiterhin > 40 KB,
24 h ohne Neustart.

## Messverfahren
1. Serielle Konsole öffnen: `pio device monitor -e ESP32-32E-35` (115200 Baud).
2. Mindestens 30 min nach Start messen (Hashrate ist ein gleitender Mittelwert).
3. Hashrate: Zeile `>>> Completed ... avg. hashrate ... KH/s` bzw. Statuszeile unten im Claude-Screen.
4. Heap: Die Firmware schreibt jede Minute
   `[CLAUDE] Heap frei=..., min. frei=..., groesster Block=...`.
   Maßgeblich ist **min. frei** (niedrigster Wert seit Start).
5. Je einmal messen: Miner-Screen ohne Bridge, Claude-Screen mit Bridge (alle 5 min `POST /claude`),
   Rotation an (z. B. 30 s).
6. Stabilität: Nach 24 h prüfen, dass `Uptime` im Miner-Screen nicht zurückgesetzt wurde.

## Ergebnisse

| Firmware / Zustand | Hashrate | Heap frei (min.) | Bemerkung |
|---|---|---|---|
| NMMiner (NMTech, Ausgangswert) | ~1,02 MH/s | ~77 KB | vom Nutzer gemessen |
| NerdMiner v2 ESP32-32E-35, Miner-Screen, ohne Bridge | _offen_ | _offen_ | |
| NerdMiner v2 ESP32-32E-35, Claude-Screen, Bridge alle 5 min | _offen_ | _offen_ | |
| NerdMiner v2 ESP32-32E-35, Rotation 30 s, 24 h | _offen_ | _offen_ | Neustarts: _offen_ |

Die Werte „offen“ lassen sich nur auf der echten Hardware messen und sind nach dem ersten Flashen einzutragen.

## Was die Änderung an Ressourcen kostet (aus dem Build)

| Build | RAM statisch | Flash |
|---|---|---|
| ESP32-2432S028R (2,8", unverändertes Upstream-Board, zum Vergleich) | 55.016 B (16,8 %) | 2.149.053 B (68,3 %) |
| ESP32-32E-35 mit Claude-Feature (inkl. Abo-Limits) | 58.464 B (17,8 %) | 2.135.741 B (67,9 %) |

Zusätzlich zur Laufzeit:
- Claude-Screen: **keine Sprites**, nur eingebaute Fonts mit Hintergrundfarbe → keine Heap-Allokation beim Zeichnen.
- JSON: zwei statische ArduinoJson-Dokumente (768 B + 1,5 KB, im RAM-Wert oben enthalten), keine Allokation pro Request
  außer dem Request-Body des Arduino-`WebServer` (max. 1 KB akzeptiert).
- Webserver läuft im Arduino-`loop()`-Task, nicht in den Mining-Tasks; kein HTTPS, kein `delay()`.
