#!/usr/bin/env bash
set -e

export DISPLAY=${DISPLAY:-:100}
export WINEPREFIX=${WINEPREFIX:-/data/wineprefix}
export LANG=ko_KR.UTF-8
export LC_ALL=ko_KR.UTF-8
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export WINEDEBUG=${WINEDEBUG:--all}

firefox_exe="$WINEPREFIX/drive_c/Program Files/Mozilla Firefox/firefox.exe"
installer="/opt/firefox/firefox-setup.exe"

if [ ! -f "$firefox_exe" ]; then
  if [ ! -f "$installer" ]; then
    echo "Firefox installer is missing: $installer" >&2
    exit 1
  fi

  echo "Installing Windows Firefox into Wine prefix..."
  wine "$installer" -ms
fi

cd "$(dirname "$firefox_exe")"
exec wine "$(basename "$firefox_exe")"
