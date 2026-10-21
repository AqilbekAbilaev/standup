#!/bin/bash
# Usage: ./build.sh            -> builds build/StandUp.app
#        ./build.sh install    -> builds, copies to ~/Applications and launches
set -euo pipefail
cd "$(dirname "$0")"
APP=build/StandUp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/StandUp" Sources/main.swift
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "install" ]]; then
  pkill -x StandUp || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/StandUp.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/StandUp.app
  echo "Installed to ~/Applications/StandUp.app"
fi
