#!/bin/zsh
# Puts Tutto's settings back to a fresh install after live testing:
# default shortcuts, all modules on, first-run welcome shown again, test usage counts
# and dismissed notices cleared, clipboard history emptied.
# Your CornerClick corner (migrated from CornerClick.app) is kept.
set -uo pipefail
pkill -x Tutto 2>/dev/null
sleep 0.5
for key in shortcuts.v1 screenshots.folder hasCompletedOnboarding modules.enabled windows.usage \
           notice.raycastDismissed panel.cornerClickExpanded cornerclick.diagnostics; do
  defaults delete ca.bryanyao.Tutto "$key" 2>/dev/null
done
# Everything copied while a test build ran (test captures, and anything else copied meanwhile)
# was recorded by Tutto; start the real install with an empty history.
rm -rf ~/Library/Application\ Support/Tutto/Clipboard
echo "Tutto test state reset"
