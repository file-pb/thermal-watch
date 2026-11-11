#!/bin/sh
# Nainstaluje ThermalWatch do ~/Applications a spustí ho při přihlášení.
set -eu
cd "$(dirname "$0")"
./build.sh

DEST="$HOME/Applications"
PLIST="$HOME/Library/LaunchAgents/cz.filipburda.thermalwatch.plist"
mkdir -p "$DEST" "$HOME/Library/LaunchAgents"
rm -rf "$DEST/ThermalWatch.app"
cp -R build/ThermalWatch.app "$DEST/"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>cz.filipburda.thermalwatch</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/ThermalWatch.app/Contents/MacOS/ThermalWatch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF

launchctl bootout "gui/$(id -u)/cz.filipburda.thermalwatch" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "ThermalWatch běží a nastartuje i po přihlášení."
echo "CLI: $(pwd)/build/thermalwatch --report 30"
