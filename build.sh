#!/bin/zsh
# Builds Folio.app and installs it into ~/Applications
set -e
cd "$(dirname "$0")"
APP=build/Folio.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/Folio"
cp Info.plist "$APP/Contents/"
if [ ! -f build/AppIcon.icns ]; then
  swiftc -O tools/MakeIcon.swift -o build/makeicon
  build/makeicon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/Folio.app
cp -R "$APP" ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Folio.app
echo "Installed ~/Applications/Folio.app"
