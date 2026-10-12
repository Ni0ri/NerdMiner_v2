# Pinbelegung ESP32-32E 3,5" (E32R35T / E32N35T)

Board: ESP32-WROOM-32E N4 (4 MB Flash, **kein PSRAM**), 3,5" TFT 480×320, Controller **ST7796** (SPI),
E32R35T mit resistivem Touch **XPT2046**, E32N35T ohne Touch.

> **Vor dem Flashen mit dem eigenen Board vergleichen** (Aufdruck auf der Rückseite, Herstellerseite/LCDwiki
> „3.5inch ESP32-32E Display“). Es gibt sehr ähnliche Boards mit anderer Belegung, z. B. das „CYD“
> **ESP32-3248S035** (Touch auf GPIO 25/32/39). Wenn die Belegung abweicht: Werte in `platformio.ini`
> (Environment `ESP32-32E-35`) anpassen, nicht raten.

| Funktion | GPIO | Build-Flag in `platformio.ini` | Quelle |
|---|---|---|---|
| LCD CS | 15 | `TFT_CS=15` | LCDwiki-Demo-Doku |
| LCD DC (RS) | 2 | `TFT_DC=2` | LCDwiki-Demo-Doku |
| SPI SCK (LCD + Touch) | 14 | `TFT_SCLK=14` | LCDwiki |
| SPI MOSI (LCD + Touch) | 13 | `TFT_MOSI=13` | LCDwiki |
| SPI MISO (LCD + Touch) | 12 | `TFT_MISO=12` | LCDwiki |
| LCD Reset | EN (Reset des ESP32) | `TFT_RST=-1` | LCDwiki |
| Hintergrundbeleuchtung | 27 (High = an, per PWM gedimmt) | `TFT_BL=27` | LCDwiki-Geräteanleitung |
| Touch CS (XPT2046) | 33 | `TOUCH_CS=33` | LCDwiki; Forenbericht E32R35T |
| Touch IRQ | 36 | nicht verwendet (Abfrage über Druckwert) | LCDwiki |
| BOOT-Taster | 0 | `PIN_BUTTON_1` in `src/drivers/devices/esp3232e35.h` | ESP32-Standard |

Nicht verwendet (bewusst, da nicht sicher belegt): RGB-LED, SD-Karte, Audio, Akku-Messung.

Touch und Display teilen sich den SPI-Bus; TFT_eSPI schaltet über `TOUCH_CS` selbst um.
**Ohne Touch (E32N35T):** in `platformio.ini` die Zeile `-DTOUCH_CS=33` entfernen, sonst kann ein offener
MISO-Pin Fehlberührungen auslösen. Bedienung dann nur über den BOOT-Taster.

## Bekannte Stellschrauben

| Symptom | Abhilfe |
|---|---|
| Farben invertiert (Schwarz erscheint weiß) | Im WLAN-Portal „Invert Display Colors“ umschalten |
| Rot und Blau vertauscht | Build-Flag `-DTFT_RGB_ORDER=TFT_BGR` ergänzen |
| Bild gestört/flackert | `SPI_FREQUENCY` von 40000000 auf 27000000 senken |
| Bild steht auf dem Kopf | BOOT-Taster doppelt klicken (dreht um 180°) |

## Quellen
- LCDwiki: 3.5inch ESP32-32E Display (E32R35T/E32N35T), Quick-Start- und ESP-IDF-Demo-Dokumentation
- Elecrow: 3.5inch ESP32 User Manual (E32R35T&E32N35T)
- rntlab-Forum: „Using an E32R35T 3.5 inch CYD instead of a 2.8 inch E32R28T“ (Touch IRQ 36, MOSI 13, MISO 12, CLK 14, CS 33)
