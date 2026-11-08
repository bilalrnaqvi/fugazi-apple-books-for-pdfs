#!/bin/zsh
# Builds the app and installs it into ~/Applications.
# APP_NAME sets the name shown in the Dock / Finder (default: Books for PDFs).
set -e
cd "$(dirname "$0")"
NAME="${APP_NAME:-$(cat .appname 2>/dev/null || echo "Books for PDFs")}"
APP="build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/Folio"
sed -e "s|<string>Folio</string>|<string>$NAME</string>|g" Info.plist > "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Folio" "$APP/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ]; then
  swiftc -O tools/MakeIcon.swift -o build/makeicon
  build/makeicon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/"$NAME".app
cp -R "$APP" ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/"$NAME".app
echo "Installed ~/Applications/$NAME.app"
