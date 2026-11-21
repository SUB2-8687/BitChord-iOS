#!/bin/bash
# Keep English and Korean localizations in an app bundle, removing other language packs.
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: $0 <app-bundle>" >&2
  exit 2
fi

APP_BUNDLE=$1
find "$APP_BUNDLE" -type d -name '*.lproj' -prune -print0 | while IFS= read -r -d '' localization; do
  language=${localization##*/}
  language=${language%.lproj}
  case "$language" in
    Base|en|en-*|ko|ko-*) ;;
    *) rm -rf "$localization" ;;
  esac
done