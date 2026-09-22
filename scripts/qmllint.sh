#!/usr/bin/env bash
# Syntax-check the plugin's QML against the Omarchy shell's own modules.
#
# qmllint is not on PATH on this machine (mise/Arch ship it under libexec), and
# it has no idea where `qs.Commons` / `qs.Ui` live unless told. The import path
# has to be laid out as <dir>/qs/Ui — the shell's modules are addressed by their
# `qs.` prefix, so a flat <dir>/Ui resolves nothing and qmllint fails with
# "Failed to import qs.Commons".
#
# The shell package directory is a symlink target, not a copy: nothing here
# writes to /usr/share/omarchy.
set -euo pipefail

cd "$(dirname "$0")/.."
PLUGIN_DIR=$PWD
OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}

QMLLINT=${QMLLINT:-}
if [[ -z $QMLLINT ]]; then
  for candidate in /usr/lib/qt6/bin/qmllint /usr/bin/qmllint "$(command -v qmllint || true)"; do
    [[ -x $candidate ]] && { QMLLINT=$candidate; break; }
  done
fi
if [[ -z ${QMLLINT:-} || ! -x $QMLLINT ]]; then
  echo "qmllint not found; set QMLLINT=/path/to/qmllint" >&2
  exit 127
fi

if [[ ! -d $OMARCHY_PATH/shell/Ui ]]; then
  echo "Omarchy shell sources not found at $OMARCHY_PATH/shell" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/qs"
ln -s "$OMARCHY_PATH/shell/Ui" "$tmp/qs/Ui"
ln -s "$OMARCHY_PATH/shell/Commons" "$tmp/qs/Commons"

# Warning category names move between Qt releases (unqualified-access became
# unqualified in 6.7, for instance). Rather than pin a set that only works on
# one Qt, read whatever this qmllint offers and force every category to `info`,
# where it does not affect the return code. Syntax errors stay fatal.
options=()
while read -r category; do
  [[ -n $category ]] && options+=("--$category" "info")
done < <("$QMLLINT" --help 2>&1 \
  | grep -oE '^\s+--[a-z][a-z0-9-]* <level>' \
  | sed -E 's/^\s*--//; s/ <level>$//' \
  | sort -u)

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  files=(BarWidget.qml Panel.qml Service.qml)
fi

status=0
for file in "${files[@]}"; do
  echo "-- $file"
  "$QMLLINT" -I "$tmp" "${options[@]}" "$file" || status=$?
done
exit "$status"
