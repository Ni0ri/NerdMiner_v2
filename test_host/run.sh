#!/usr/bin/env bash
# Host unit tests for src/claude (formatting, JSON parsing) - no ESP32 needed.
set -euo pipefail
cd "$(dirname "$0")"
AJ=.deps/ArduinoJson
if [ ! -d "$AJ" ]; then
  git -c advice.detachedHead=false clone -q --depth 1 --branch v6.21.5 https://github.com/bblanchon/ArduinoJson.git "$AJ"
fi
FLAGS="-std=c++17 -Wall -Wextra -Werror -DCLAUDE_FEATURE=1 -DARDUINOJSON_USE_LONG_LONG=1 -I$AJ/src -I../src/claude"
SRC="test_claude.cpp ../src/claude/claudeFormat.cpp ../src/claude/claudeUsage.cpp"
g++ $FLAGS $SRC -o .deps/test_claude
.deps/test_claude
# 32-bit build is closer to the ESP32 (pointer size, ArduinoJson slot size) - optional if multilib is missing
if echo 'int main(){}' | g++ -m32 -x c++ - -o /dev/null 2>/dev/null; then
  g++ -m32 $FLAGS $SRC -o .deps/test_claude32
  .deps/test_claude32 | tail -1
else
  echo "(32-Bit-Lauf übersprungen: g++ -m32 nicht verfügbar)"
fi
