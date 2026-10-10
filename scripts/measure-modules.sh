#!/bin/zsh
# Measures Tutto's idle cost with different sets of modules on (launches the build in
# build/Products.noindex/Tutto.app without global shortcuts, so it can run beside apps that use the same keys).
#   scripts/measure-modules.sh [seconds-per-run]
set -uo pipefail
cd "$(dirname "$0")/.."
secs=${1:-90}
run() {
  local label=$1; shift
  pkill -x Tutto; sleep 1
  defaults write ca.bryanyao.Tutto modules.enabled -array "$@"
  (nohup ./build/Products.noindex/Tutto.app/Contents/MacOS/Tutto --background --no-shortcuts > /dev/null 2>&1 &)
  sleep 6
  echo "== $label"
  ./scripts/measure.sh $secs Tutto | tail -1
}
run "none"
run "system+sensors+windows+screenshots+archives" system sensors windows screenshots archives
run "clipboard only" clipboard
run "corner only" corner
run "all" system sensors clipboard windows screenshots archives corner
