#!/bin/zsh
#
#  Created by YueRuo on 2026/11/2.
#

set -eu
umask 022
PROJECT_ROOT="${0:A:h:h}"
SOURCE_DIR="$PROJECT_ROOT/Sources"
RESOURCE_DIR="$PROJECT_ROOT/Resources"
OUTPUT_DIR="$PROJECT_ROOT/dist"
APP_BUILD_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}sidecar-build.XXXXXXXX")
trap '/bin/rm -rf "$APP_BUILD_DIR"' EXIT
APP_DIR="$APP_BUILD_DIR/随航登录助手.app"

if (( $# != 0 )); then
  print -u2 -r -- 'Usage: ./scripts/build.command'
  exit 2
fi
if [[ -L "$OUTPUT_DIR" || ( -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ) ]]; then
  print -u2 -r -- 'dist must be a regular directory inside the project.'
  exit 1
fi
for RESOURCE_LANGUAGE in zh-Hans en; do
  /usr/bin/plutil -lint "$RESOURCE_DIR/Localizations/$RESOURCE_LANGUAGE.lproj/Localizable.strings" \
    "$RESOURCE_DIR/Localizations/$RESOURCE_LANGUAGE.lproj/InfoPlist.strings" \
    "$RESOURCE_DIR/Shortcuts/$RESOURCE_LANGUAGE/Template.plist"
done
if [[ ! -f "$RESOURCE_DIR/Shortcuts/zh-Hans/iPad随航连接.shortcut" || \
      ! -f "$RESOURCE_DIR/Shortcuts/en/iPad Sidecar Connect.shortcut" ]]; then
  print -u2 -r -- 'The signed Chinese and English shortcut templates are required.'
  exit 1
fi
/bin/mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
/bin/cp "$RESOURCE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
/bin/cp -R "$RESOURCE_DIR/Localizations/." "$APP_DIR/Contents/Resources/"
/bin/cp "$RESOURCE_DIR/Shortcuts/zh-Hans/iPad随航连接.shortcut" "$APP_DIR/Contents/Resources/zh-Hans.lproj/"
/bin/cp "$RESOURCE_DIR/Shortcuts/en/iPad Sidecar Connect.shortcut" "$APP_DIR/Contents/Resources/en.lproj/"
/bin/chmod 644 "$APP_DIR/Contents/Resources/zh-Hans.lproj/iPad随航连接.shortcut" \
  "$APP_DIR/Contents/Resources/en.lproj/iPad Sidecar Connect.shortcut"

for CPU_ARCH in arm64 x86_64; do
  /usr/bin/xcrun clang -arch "$CPU_ARCH" -mmacosx-version-min=14.2 \
    -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
    -framework AppKit -framework Foundation -framework ServiceManagement \
    "$SOURCE_DIR/App/HeadlessSidecarLogin.m" -o "$APP_BUILD_DIR/HeadlessSidecarLogin-$CPU_ARCH"
  /usr/bin/xcrun clang -arch "$CPU_ARCH" -mmacosx-version-min=14.2 \
    -fobjc-arc -O2 -Wall -Wextra -Werror -framework Foundation \
    "$SOURCE_DIR/Helpers/SidecarStatus.m" -o "$APP_BUILD_DIR/SidecarStatus-$CPU_ARCH"
  /usr/bin/xcrun clang -arch "$CPU_ARCH" -mmacosx-version-min=14.2 \
    -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -framework Foundation -framework CoreFoundation \
    "$SOURCE_DIR/Helpers/SidecarLauncher.m" -o "$APP_BUILD_DIR/SidecarLauncher-$CPU_ARCH"
done
/usr/bin/xcrun lipo -create "$APP_BUILD_DIR/HeadlessSidecarLogin-arm64" \
  "$APP_BUILD_DIR/HeadlessSidecarLogin-x86_64" -output "$APP_DIR/Contents/MacOS/HeadlessSidecarLogin"
for HELPER in SidecarStatus SidecarLauncher; do
  /usr/bin/xcrun lipo -create "$APP_BUILD_DIR/$HELPER-arm64" "$APP_BUILD_DIR/$HELPER-x86_64" \
    -output "$APP_DIR/Contents/Helpers/$HELPER"
  /usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR/Contents/Helpers/$HELPER"
done

/usr/bin/xcrun clang -fobjc-arc -O2 -framework AppKit \
  "$PROJECT_ROOT/Tools/MakeIcon.m" -o "$APP_BUILD_DIR/make-icon"
/bin/mkdir "$APP_BUILD_DIR/AppIcon.iconset"
"$APP_BUILD_DIR/make-icon" "$APP_BUILD_DIR/AppIcon.iconset" "$APP_DIR/Contents/Resources/AppIcon.icns"

"$PROJECT_ROOT/scripts/test.command" "$APP_DIR"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

# Only replace the generated output after compilation, tests and signing succeed.
/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -rf "$OUTPUT_DIR/随航登录助手.app"
/bin/mv "$APP_DIR" "$OUTPUT_DIR/随航登录助手.app"
print -r -- "Built: $OUTPUT_DIR/随航登录助手.app"
/usr/bin/xcrun lipo -archs "$OUTPUT_DIR/随航登录助手.app/Contents/MacOS/HeadlessSidecarLogin"
