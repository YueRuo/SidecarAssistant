#!/bin/zsh
#
#  Created by YueRuo on 2026/11/2.
#

set -eu
umask 022
PROJECT_ROOT="${0:A:h:h}"
RESOURCE_DIR="$PROJECT_ROOT/Resources"
TEST_BUILD_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}sidecar-tests.XXXXXXXX")
trap '/bin/rm -rf "$TEST_BUILD_DIR"' EXIT

if (( $# > 1 )); then
  print -u2 -r -- 'Usage: ./scripts/test.command [path/to/随航登录助手.app]'
  exit 2
fi

if (( $# == 1 )); then
  TEST_APP="$1"
  if [[ ! -d "$TEST_APP/Contents/Resources" ]]; then
    print -u2 -r -- 'The test app bundle does not contain Resources.'
    exit 2
  fi
else
  TEST_APP="$TEST_BUILD_DIR/LocalizationFixture.app"
  /bin/mkdir -p "$TEST_APP/Contents/Resources"
  /bin/cp "$RESOURCE_DIR/Info.plist" "$TEST_APP/Contents/Info.plist"
  /bin/cp -R "$RESOURCE_DIR/Localizations/." "$TEST_APP/Contents/Resources/"
  /bin/cp "$RESOURCE_DIR/Shortcuts/zh-Hans/iPad随航连接.shortcut" "$TEST_APP/Contents/Resources/zh-Hans.lproj/"
  /bin/cp "$RESOURCE_DIR/Shortcuts/en/iPad Sidecar Connect.shortcut" "$TEST_APP/Contents/Resources/en.lproj/"
fi

/usr/bin/xcrun clang -mmacosx-version-min=14.2 -fobjc-arc -fblocks -O2 \
  -Wall -Wextra -Werror -Wno-unused-function \
  -framework AppKit -framework Foundation -framework ServiceManagement \
  "$PROJECT_ROOT/Tests/AppTests.m" -o "$TEST_BUILD_DIR/app-tests"
"$TEST_BUILD_DIR/app-tests" "$TEST_APP"

/usr/bin/xcrun clang -mmacosx-version-min=14.2 -fobjc-arc -fblocks -O2 \
  -Wall -Wextra -Werror -Wno-unused-function \
  -framework Foundation -framework CoreFoundation \
  "$PROJECT_ROOT/Tests/SidecarLauncherTests.m" -o "$TEST_BUILD_DIR/helper-tests"
"$TEST_BUILD_DIR/helper-tests"
