#!/bin/sh
# Build ThermalWatch: jeden binárník + minimální .app bundle pro menu bar.
# Bez Xcode projektu a bez SwiftPM – stačí swiftc z Command Line Tools.
set -eu
cd "$(dirname "$0")"
APP="build/ThermalWatch.app"

mkdir -p build "$APP/Contents/MacOS"
# -import-objc-header: notify(3) není v Darwin modulu, přes hlavičku se dotáhne.
swiftc -O -import-objc-header src/shim.h -o build/thermalwatch \
  src/Pressure.swift src/Config.swift src/Sampler.swift src/Store.swift src/Report.swift \
  src/ChartView.swift src/Alerter.swift src/App.swift src/main.swift

cp build/thermalwatch "$APP/Contents/MacOS/ThermalWatch"
cp resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc podpis: bez něj macOS bundle po každém buildu znovu zkoumá.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "build/thermalwatch     (CLI)"
echo "build/ThermalWatch.app (menu bar)"
