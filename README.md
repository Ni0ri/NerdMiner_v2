# NerdMiner v2 + Claude-Nutzungsanzeige (ESP32-32E, 3,5")

Fork von [NerdMiner v2](https://github.com/BitMaker-hub/NerdMiner_v2) für das **ESP32-32E mit 3,5"-Display
(480×320, ST7796)**. Der ESP32 betreibt weiter Bitcoin-**Solo**-Mining (Lotto-Prinzip) und zeigt zusätzlich auf
einem eigenen Screen die **Claude-Nutzung** (Tokens und Kosten).

Die ursprüngliche englische NerdMiner-Anleitung steht in [README_NerdMiner_v2.md](README_NerdMiner_v2.md).

```
[Windows-PC]                                   [ESP32]
bridge\ClaudeMinerBridge.ps1 (alle 5 min)      NerdMiner v2 (dieser Fork)
  ├─ holt Claude-Nutzungsdaten          HTTP     ├─ Mining wie gehabt (Solo-Pool)
  └─ POST /claude  (kleines JSON)  ──────────►   ├─ Endpoint POST/GET /claude (Port 80)
                                     LAN         └─ zusätzlicher Screen "Claude"
```

**Wichtig:** Der ESP32 macht für das Claude-Feature kein HTTPS und kennt keinen API-Key. Ohne PSRAM würde TLS
40–50 KB Heap kosten und den Miner gefährden. Alle Internet- und API-Zugriffe macht der PC, der ESP bekommt im LAN
nur fertige Zahlen.

| Ordner/Datei | Inhalt |
|---|---|
| `platformio.ini`, `src/` | Firmware (Fork). Neu: Environment `ESP32-32E-35`, `src/claude/`, `src/drivers/displays/esp32_32e_35DisplayDriver.cpp` |
| `bridge/` | PowerShell-Bridge, `Install-Task.ps1`, `config.example.json`, Pester-Tests |
| `docs/` | [Pinbelegung](docs/Pinbelegung.md), [Hashrate- und Heap-Vergleich](docs/Hashrate-und-Heap.md) |
| `test_host/` | Unit-Tests der Claude-Logik auf dem PC (ohne ESP32) |

---

## 1. Board prüfen

Pinbelegung mit dem eigenen Board vergleichen: [docs/Pinbelegung.md](docs/Pinbelegung.md).
Bei Abweichungen erst `platformio.ini` anpassen, dann flashen.

## 2. Firmware flashen

### Variante A: PlatformIO (VS Code oder Kommandozeile)
```powershell
git clone https://github.com/<dein-konto>/NerdMiner_v2.git
cd NerdMiner_v2
pio run -e ESP32-32E-35 -t erase      # einmalig beim Umstieg von NMMiner: Flash komplett löschen
pio run -e ESP32-32E-35 -t upload
pio device monitor -e ESP32-32E-35    # Log ansehen (115200 Baud)
```

### Variante B: Web-Flasher (ohne Entwicklungsumgebung)
1. Fertige Datei `ESP32-32E-35_factory.bin` aus dem GitHub-Actions-Lauf „Claude-Display“ herunterladen
   (Lauf öffnen, unten unter **Artifacts** → `ESP32-32E-35-firmware`, ZIP entpacken).
   Beim Bauen mit PlatformIO liegt sie unter `firmware/<version>/`.
2. Im Chrome/Edge <https://espressif.github.io/esptool-js/> öffnen, Board per USB verbinden, „Connect“.
3. „Erase Flash“ (einmalig beim Umstieg von NMMiner), dann die factory.bin an Adresse **0x0** flashen.

## 3. WLAN und Pool einrichten

1. Nach dem Flashen öffnet der ESP einen Access Point **NerdMinerAP** (Kennwort laut NerdMiner-Standard:
   `MineYourCoins`). Mit dem Handy verbinden, das Portal öffnet sich (sonst `http://192.168.4.1`).
2. WLAN auswählen und Kennwort eingeben.
3. Pool für **echtes Solo-Mining** eintragen:

   | Pool | Port | Benutzer |
   |---|---|---|
   | `public-pool.io` (Standard) | `21496` | eigene BTC-Adresse |
   | `solo.ckpool.org` (Alternative) | `3333` | eigene BTC-Adresse |

   Hinweis: Der bisher genutzte `v2.stratum.braiins.com` ist ein normaler Pool (Ausschüttung anteilig),
   **kein** Solo-Pool.
4. Abschnitt **Claude-Anzeige** im Portal:
   - **X-Token** (optional): beliebige Zeichenkette (max. 40 Zeichen). Ist sie gesetzt, akzeptiert der ESP
     `POST/GET /claude` nur mit Header `X-Token: <wert>`. Leer = kein Schutz.
   - **Rotation**: Sekunden, nach denen automatisch zwischen Miner- und Claude-Screen gewechselt wird; `0` = aus.
5. Speichern. Der ESP verbindet sich und zeigt im seriellen Log
   `[CLAUDE] Endpoint bereit: http://<ip>/claude`. Die IP am besten im Router fest zuweisen.

Portal später erneut öffnen: BOOT-Taster **5 s** halten (setzt die Konfiguration zurück).

## 4. Bedienung am Gerät

| Aktion | Wirkung |
|---|---|
| Display antippen (E32R35T) | nächster Screen: Miner → Uhr → Global Hash → BTC-Preis → **Claude** → … |
| BOOT-Taster 1× | nächster Screen |
| BOOT-Taster 2× | Anzeige um 180° drehen |
| BOOT-Taster 5 s | Konfiguration zurücksetzen, Portal startet |

Die vier NerdMiner-Screens sind für 320×240 gebaut und werden auf dem 480×320-Display **zentriert** (schwarzer
Rand). Der Claude-Screen nutzt die volle Fläche.

### Claude-Screen
- Kosten heute und Monat, Tokens ein/aus (kompakt, z. B. `1,2 M`), Balken „Monat vs. Budget“
  (grün < 75 %, gelb < 100 %, rot ab 100 %), Zeitpunkt der letzten Aktualisierung.
- Statuszeile unten: Hashrate, Best Diff, Temperatur.
- Fehlende Werte werden als `-` angezeigt.
- Seit Neustart keine Daten: „Keine Daten - Bridge auf dem PC aktiv?“. Der Miner läuft davon unabhängig normal.
- Letzte Daten älter als 30 min: „Daten veraltet!“ (rot).
- Beschriftung der Quelle oben rechts: „Admin API (echte Kosten)“ bzw. „ccusage: API-Preis, kein Abo“.

## 5. Endpoint testen (curl)

```powershell
# Beispieldaten in eine Datei schreiben (umgeht Unterschiede beim Quoting zwischen PowerShell 5.1 und 7)
'{"source":"test","updated":"2026-10-12T12:55:00+02:00","today":{"input_tokens":120000,"output_tokens":45000,"cost_usd":1.84},"month":{"input_tokens":3100000,"output_tokens":980000,"cost_usd":41.20},"budget_usd":100.0}' |
  Set-Content -Path claude-test.json -Encoding ASCII

# Senden (curl.exe, damit nicht der PowerShell-Alias greift); ohne X-Token im Portal den -H "X-Token..." weglassen
curl.exe -X POST http://192.0.2.50/claude -H "Content-Type: application/json" -H "X-Token: meintoken" --data-binary "@claude-test.json"
# -> {"ok":true}

# Zuletzt empfangene Daten lesen
curl.exe http://192.0.2.50/claude -H "X-Token: meintoken"
```
`192.0.2.50` durch die IP des ESP ersetzen. Einfacher geht es mit der Bridge: `ClaudeMinerBridge.ps1 -Test`.

| Antwort | Bedeutung |
|---|---|
| `200 {"ok":true}` | Daten übernommen |
| `400` | kein/ungültiges JSON (Wurzel muss ein Objekt sein) |
| `401` | X-Token fehlt oder falsch |
| `413` | Body größer als 1 KB |

Format (alle Felder optional, unbekannte Felder werden ignoriert):
```json
{
  "source": "admin_api",
  "updated": "2026-10-12T12:55:00+02:00",
  "today":  { "input_tokens": 120000, "output_tokens": 45000, "cost_usd": 1.84 },
  "month":  { "input_tokens": 3100000, "output_tokens": 980000, "cost_usd": 41.20 },
  "budget_usd": 100.0
}
```
`GET /claude` liefert zusätzlich `received` (true/false) und `age_s` (Sekunden seit Empfang).

## 6. Bridge auf dem Windows-PC einrichten

```powershell
cd <repo>\bridge
.\Install-Task.ps1 -WhatIf     # Trockenlauf: zeigt Kopieraktionen und geplante Aufgabe
.\Install-Task.ps1             # kopiert nach C:\Tools\ClaudeMinerBridge, Aufgabe alle 5 min
notepad C:\Tools\ClaudeMinerBridge\config.json
C:\Tools\ClaudeMinerBridge\ClaudeMinerBridge.ps1 -Test   # Beispieldaten senden -> Screen prüfen
```

`config.json`:

| Feld | Bedeutung |
|---|---|
| `esp_host` | IP oder Hostname des ESP (optional mit `:port`) |
| `esp_token` | gleicher Wert wie „X-Token“ im NerdMiner-Portal, leer = ohne |
| `source` | `admin_api` oder `ccusage` |
| `budget_usd` | Monatsbudget für den Fortschrittsbalken (leer/0 = kein Balken) |
| `admin_key_file` | Datei mit dem DPAPI-verschlüsselten Admin-Key (Standard `adminkey.dpapi`) |
| `ccusage_command`, `ccusage_args` | Aufruf von ccusage, Standard `npx --yes ccusage@latest` |
| `log_retention_days` | Logdateien `Log_yyyy-MM-dd.log` älter als n Tage werden gelöscht (Standard 14) |

`config.json` und `*.dpapi` stehen in `bridge/.gitignore` und landen nie im Repository.

### Datenquelle `admin_api` (Anthropic Console / API-Nutzung)
1. In der Claude Console einen **Admin-API-Key** (`sk-ant-admin...`) anlegen (nur für Organisationen verfügbar).
2. Einmalig verschlüsselt ablegen (DPAPI, nur derselbe Windows-Benutzer auf demselben PC kann ihn lesen):
   ```powershell
   C:\Tools\ClaudeMinerBridge\ClaudeMinerBridge.ps1 -SetAdminKey
   ```
3. `"source": "admin_api"` setzen, mit `-WhatIf -Verbose` prüfen, dann normal laufen lassen.

Genutzte Endpunkte (geprüft gegen die offizielle Doku „Usage and Cost API“):
`GET /v1/organizations/usage_report/messages` und `GET /v1/organizations/cost_report`, Header
`x-api-key` und `anthropic-version: 2023-06-01`, Paginierung über `has_more`/`next_page`.
- Tokens heute: Stunden-Buckets ab Mitternacht **Europe/Berlin**.
- Tokens Monat: Tages-Buckets ab dem 1. des Monats; die API kennt nur **UTC-Tage**.
- Kosten: Der Cost-Report liefert nur Tages-Buckets in UTC. „Heute“ ist daher der aktuelle UTC-Tag
  (bis zu 2 h Versatz zur Berliner Zeit). Beträge kommen in Cent und werden in USD umgerechnet.
- Input-Tokens = ungecachte + Cache-Lese- + Cache-Schreib-Tokens.
- Die API liefert Daten mit etwa 5 min Verzögerung; 3 Abfragen alle 5 min liegen weit unter dem empfohlenen Limit.

### Datenquelle `ccusage` (Claude Code mit Pro/Max-Abo)
- Benötigt Node.js (`npx`). Aufruf: `npx --yes ccusage@latest daily --json --since <Monatserster> --timezone Europe/Berlin`
  (geprüft mit ccusage 20.0.30, ältere Versionen mit Feld `date` statt `period` werden ebenfalls verstanden).
- Wertet die lokalen Claude-Code-Logs des angemeldeten Benutzers aus.
- **Die Kosten sind rechnerische API-Preise, keine echten Abo-Kosten.** Das Display beschriftet das entsprechend.
- Für die Nutzungslimits des claude.ai-Abos gibt es keine offizielle API; sie werden bewusst nicht per Scraping
  oder über inoffizielle Endpunkte abgefragt.

### Bridge-Parameter
| Parameter | Wirkung |
|---|---|
| `-Test` | sendet feste Beispieldaten (`source: test`) |
| `-WhatIf` | fragt die Quelle ab und protokolliert das JSON, sendet aber nichts |
| `-SetAdminKey` | Admin-Key verdeckt abfragen und per DPAPI speichern |
| `-SelfTest` | eingebaute Tests ohne Netzwerk (`n/n Tests grün`) |

Aufgabe entfernen: `.\Install-Task.ps1 -Uninstall`.

## 7. Abnahme-Checkliste

- [ ] Miner läuft 24 h ohne Neustart, Hashrate höchstens ~5 % unter Ausgangswert → [docs/Hashrate-und-Heap.md](docs/Hashrate-und-Heap.md)
- [ ] Freier Heap (min.) im Log > 40 KB
- [ ] Claude-Screen zeigt Werte innerhalb von 5 min nach dem Bridge-Lauf
- [ ] Ohne Bridge läuft der Miner normal, Claude-Screen zeigt „Keine Daten“
- [ ] Keine Secrets im Repository (`config.json`, `*.dpapi` ignoriert; CI prüft zusätzlich)

## 8. Entwicklung und Tests

```bash
test_host/run.sh                       # Unit-Tests src/claude (g++)
pio run -e ESP32-32E-35                # Firmware bauen
```
```powershell
Invoke-Pester bridge/tests             # Bridge-Tests (Pester 5)
.\bridge\ClaudeMinerBridge.ps1 -SelfTest
```
Die GitHub-Action `.github/workflows/claude-display.yml` führt alles aus, auch unter Windows PowerShell 5.1.

## Lizenz

Wie NerdMiner v2: **MIT** (siehe [LICENSE](LICENSE), Copyright Bitmaker). Die Erweiterungen in diesem Fork
stehen unter derselben Lizenz.
