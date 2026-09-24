#!/usr/bin/env bash
# Install the working copy into the shell's plugin directory and reload it.
#
# Copies rather than symlinks on purpose: `omarchy plugin validate` refuses any
# symlink inside a plugin folder, and the shell's catalogue walks that directory
# with `find -L`, which makes a link fragile in ways a copy is not.
set -euo pipefail

cd "$(dirname "$0")/.."
PLUGIN_ID=io.github.tecknozic.skybrief
DEST="${OMARCHY_PLUGIN_DIR:-$HOME/.config/omarchy/plugins}/$PLUGIN_ID"

/usr/bin/rsync -a --delete --exclude .git --exclude node_modules ./ "$DEST/"

# QML components reload on change, but the JS files are cached by the shell's
# engine independently of a component rescan: only a shell restart picks up a
# change to Model.js.
echo "Synced to $DEST"
echo "Component changes are live; run 'omarchy restart shell' after editing Model.js."

if [[ "${1:-}" != "--no-reload" ]]; then
  omarchy-shell shell rescanPlugins
fi
