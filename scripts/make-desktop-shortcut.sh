#!/usr/bin/env bash
# Build GrokIsland (if needed) and put a Finder alias named 「NewIsland」 on the Desktop.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this script on a Mac." >&2
  exit 1
fi

xcodebuild -scheme GrokIsland -configuration Debug -destination 'platform=macOS' -quiet build

APP="$(find ~/Library/Developer/Xcode/DerivedData -name 'GrokIsland.app' -path '*Debug*' 2>/dev/null | head -n 1 || true)"
if [[ -z "$APP" ]]; then
  echo "error: could not find GrokIsland.app after build" >&2
  exit 1
fi

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/NewIsland.app"
cp -R "$APP" "$DEST/NewIsland.app"

osascript <<'APPLESCRIPT'
set appPath to (POSIX file (POSIX path of (path to home folder as text) & "Applications/NewIsland.app"))
set desk to path to desktop folder
tell application "Finder"
    if exists file "NewIsland" of desk then
        delete file "NewIsland" of desk
    end if
    make new alias file at desk to appPath with properties {name:"NewIsland"}
end tell
APPLESCRIPT

echo "Desktop alias created: ~/Desktop/NewIsland"
echo "App copy: ~/Applications/NewIsland.app"
