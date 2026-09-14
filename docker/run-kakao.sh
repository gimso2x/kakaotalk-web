#!/usr/bin/env bash
set -euo pipefail

export WINEPREFIX="${WINEPREFIX:-/data/wineprefix}"
export LANG="${LANG:-ko_KR.UTF-8}"
export LC_ALL="ko_KR.UTF-8"
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export DISPLAY="${DISPLAY:-:100}"

KAKAOTALK_EXE="${KAKAOTALK_EXE:-$WINEPREFIX/drive_c/Program Files/Kakao/KakaoTalk/KakaoTalk.exe}"

get_center_coords() {
  local res sw sh cx cy
  res=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ { print $2 }' || echo "1280x800")
  sw=${res%x*}
  sh=${res#*x}
  cx=$(( (sw - 390) / 2 ))
  cy=$(( (sh - 640) / 2 ))
  [ "$cx" -lt 10 ] && cx=60
  [ "$cy" -lt 10 ] && cy=60
  echo "$cx $cy"
}

# 1. If KakaoTalk window already exists on screen, bring it to front
if wmctrl -l 2>/dev/null | grep -qE "카카오톡|KakaoTalk"; then
  read -r cx cy < <(get_center_coords)
  wmctrl -r "카카오톡" -b remove,hidden 2>/dev/null || wmctrl -r "KakaoTalk" -b remove,hidden 2>/dev/null || true
  wmctrl -r "카카오톡" -e "0,$cx,$cy,390,640" 2>/dev/null || wmctrl -r "KakaoTalk" -e "0,$cx,$cy,390,640" 2>/dev/null || true
  wmctrl -a "카카오톡" 2>/dev/null || wmctrl -a "KakaoTalk" 2>/dev/null || true
  exit 0
fi

# 2. If process exists but window is unmapped, try to map it first before killing
if pgrep -x "KakaoTalk.exe" >/dev/null 2>&1; then
  ids=$(xwininfo -root -tree 2>/dev/null | awk '/"카카오톡"|"KakaoTalk"/ { print $1 }' || true)
  if [ -n "$ids" ]; then
    for id in $ids; do
      xdotool windowmap "$id" 2>/dev/null || true
    done
    sleep 0.5
    if wmctrl -l 2>/dev/null | grep -qE "카카오톡|KakaoTalk"; then
      read -r cx cy < <(get_center_coords)
      wmctrl -r "카카오톡" -e "0,$cx,$cy,390,640" 2>/dev/null || wmctrl -r "KakaoTalk" -e "0,$cx,$cy,390,640" 2>/dev/null || true
      wmctrl -a "카카오톡" 2>/dev/null || wmctrl -a "KakaoTalk" 2>/dev/null || true
      exit 0
    fi
  fi

  # If still not recoverable, clean it up
  pkill -x "KakaoTalk.exe" 2>/dev/null || true
  for _ in $(seq 1 10); do
    pgrep -x "KakaoTalk.exe" >/dev/null 2>&1 || break
    sleep 0.2
  done
  pkill -9 -x "KakaoTalk.exe" 2>/dev/null || true
fi

# 3. Ensure D-Bus session exists for fcitx5
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  exec dbus-run-session -- "$0" "$@"
fi

# 4. Start fcitx5 input method if not running
if ! pgrep -x "fcitx5" >/dev/null 2>&1; then
  fcitx5 -d --replace >/tmp/fcitx5-kakao.log 2>&1 || true
  for _ in $(seq 1 25); do
    if fcitx5-remote >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  fcitx5-remote -s hangul >/tmp/fcitx5-remote.log 2>&1 || true
  fcitx5-remote -o >>/tmp/fcitx5-remote.log 2>&1 || true
fi

cleanup() {
  if [ -n "${wine_pid:-}" ]; then
    kill -TERM "$wine_pid" 2>/dev/null || true
  fi
}
trap cleanup SIGTERM SIGINT

cd "$(dirname "$KAKAOTALK_EXE")"
WINEDEBUG=-all wine "$(basename "$KAKAOTALK_EXE")" &
wine_pid=$!

# Pull the KakaoTalk window into the visible desktop
(
  read -r cx cy < <(get_center_coords)
  for _ in $(seq 1 40); do
    ids=$(xwininfo -root -tree 2>/dev/null | awk '/"카카오톡"|"KakaoTalk"/ { print $1 }' || true)
    if [ -n "$ids" ]; then
      for id in $ids; do
        xdotool windowmap "$id" 2>/dev/null || true
      done
    fi

    if wmctrl -l 2>/dev/null | grep -qE "카카오톡|KakaoTalk"; then
      wmctrl -r "카카오톡" -e "0,$cx,$cy,390,640" 2>/dev/null || wmctrl -r "KakaoTalk" -e "0,$cx,$cy,390,640" 2>/dev/null || true
      wmctrl -a "카카오톡" 2>/dev/null || wmctrl -a "KakaoTalk" 2>/dev/null || true
      break
    fi
    sleep 0.5
  done
) &

wait "$wine_pid"
