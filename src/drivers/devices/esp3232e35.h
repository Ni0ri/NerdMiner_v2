#ifndef _ESP32_32E_35
#define _ESP32_32E_35

// ESP32-32E (WROOM-32E, N4, no PSRAM) with 3.5" ST7796 480x320 SPI display
// (LCDwiki E32R35T resistive touch / E32N35T without touch).
// Display/touch pins are set via build flags in platformio.ini, see docs/Pinbelegung.md.

#define PIN_BUTTON_1 0   // BOOT button: click = next screen, double click = rotate, 5 s = reset config

// calls api to retrieve worker metrics
#define SCREEN_WORKERS_ENABLE (1)

#endif
