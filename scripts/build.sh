#!/bin/zsh
# Builds Tutto.app: compiles the Swift package, assembles the bundle (app, Finder
# extension, fan helper, icon), and signs it inside-out.
#
#   scripts/build.sh            release build into build/Products.noindex/Tutto.app
#   scripts/build.sh --debug    debug build (enables --snapshot rendering)
#   scripts/build.sh --install  also replaces /Applications/Tutto.app and registers it
#
# Signs with your Apple Development identity when one exists (so macOS keeps
# Accessibility and Screen Recording approvals across rebuilds), else ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
  esac
done

VERSION=1.0.0
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
IDENTITY=${TUTTO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}
IDENTITY=${IDENTITY:--}

swift build -c $CONFIG --arch arm64 --product Tutto
swift build -c $CONFIG --arch arm64 --product TuttoFinder
swift build -c $CONFIG --arch arm64 --product TuttoHelper
BIN=.build/arm64-apple-macosx/$CONFIG

APP=build/Products.noindex/Tutto.app   # .noindex: Spotlight lists only the installed copy
rm -rf $APP
mkdir -p $APP/Contents/{MacOS,Resources,PlugIns,Library/LaunchDaemons}

cp $BIN/Tutto $APP/Contents/MacOS/Tutto
cp $BIN/TuttoHelper $APP/Contents/MacOS/TuttoHelper
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > $APP/Contents/Info.plist
cp -R Resources/Fonts $APP/Contents/Resources/Fonts   # Geist, registered via ATSApplicationFontsPath
if [[ -f Resources/ca.bryanyao.Tutto.helper.plist ]]; then
  cp Resources/ca.bryanyao.Tutto.helper.plist $APP/Contents/Library/LaunchDaemons/
fi

EXT=$APP/Contents/PlugIns/TuttoFinder.appex
mkdir -p $EXT/Contents/MacOS
cp $BIN/TuttoFinder $EXT/Contents/MacOS/TuttoFinder

# Release: the symbols go to build/Symbols as dSYMs (crash reports, `sample` and `atos` find them by
# UUID), and the shipped binaries leave their symbol tables out: the app binary goes from about
# 11 MB to under 5 MB. Debug builds keep everything.
if [[ $CONFIG == release ]]; then
  rm -rf build/Symbols && mkdir -p build/Symbols
  for name in Tutto TuttoHelper TuttoFinder; do
    dsymutil $BIN/$name -o build/Symbols/$name.dSYM 2>/dev/null || echo "dsymutil failed for $name (symbols stay in the binary)" >&2
  done
  for binary in $APP/Contents/MacOS/Tutto $APP/Contents/MacOS/TuttoHelper $EXT/Contents/MacOS/TuttoFinder; do
    [[ -d build/Symbols/${binary:t}.dSYM ]] && strip -x $binary 2>/dev/null
  done
fi
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/FinderExtension-Info.plist > $EXT/Contents/Info.plist

# actool reports failures in its plist output; show them instead of stopping silently. Paths are
# absolute: actool hands them to a shared ibtoold daemon, which reads relative ones from its own
# folder (wherever another project's build started it).
if ! ACTOOL_OUT=$(xcrun actool --compile "$PWD/$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$PWD/build/actool-partial.plist" "$PWD/Resources/AppIcon.icon" 2>&1); then
  echo "$ACTOOL_OUT" | grep -A2 "<key>description</key>" | head -6
  echo "actool failed compiling the icon. A stuck asset compiler helps clear with: pkill -f ibtoold" >&2
  exit 1
fi

# Inside-out: helper, extension, then the app.
SIGN=(codesign --force --sign "$IDENTITY" --timestamp=none)
[[ $IDENTITY != "-" ]] && SIGN+=(--options runtime)
$SIGN --identifier ca.bryanyao.Tutto.helper $APP/Contents/MacOS/TuttoHelper
$SIGN --entitlements Resources/FinderExtension.entitlements $EXT
$SIGN --entitlements Resources/Tutto.entitlements $APP
codesign --verify --deep --strict $APP

echo "Tutto $VERSION ($BUILD) $CONFIG  $(du -sh $APP | cut -f1)  signed: $IDENTITY"

if (( INSTALL )); then
  # Ask a running Tutto to quit through its own URL (no Apple Events), so it resets fans cleanly.
  if pgrep -x Tutto > /dev/null; then
    open -g "tutto://do/quit" 2>/dev/null || true
    for _ in {1..25}; do pgrep -x Tutto > /dev/null || break; sleep 0.2; done
    pkill -x Tutto 2>/dev/null || true
  fi
  rm -rf /Applications/Tutto.app
  ditto $APP /Applications/Tutto.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tutto.app
  pluginkit -a /Applications/Tutto.app/Contents/PlugIns/TuttoFinder.appex 2>/dev/null || true
  # Leave only the installed copy registered (the build folder copy would otherwise compete).
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
  pluginkit -r "$PWD/$EXT" 2>/dev/null || true
  echo "installed /Applications/Tutto.app"
fi
