#!/bin/sh
# Zastaví a odinstaluje ThermalWatch. Nasbíraná data nechává na pokoji.
set -eu
PLIST="$HOME/Library/LaunchAgents/cz.filipburda.thermalwatch.plist"
launchctl bootout "gui/$(id -u)/cz.filipburda.thermalwatch" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/ThermalWatch.app"
pkill -f "ThermalWatch.app/Contents/MacOS/ThermalWatch" 2>/dev/null || true
echo "Odinstalováno. Data zůstala v ~/Library/Application Support/ThermalWatch/"
