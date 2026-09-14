#!/usr/bin/env bash
set -euo pipefail

export WINEPREFIX="${WINEPREFIX:-/data/wineprefix}"
export LANG="${LANG:-ko_KR.UTF-8}"
export LC_ALL="${LC_ALL:-ko_KR.UTF-8}"
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export DISPLAY="${DISPLAY:-:100}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
export ENABLE_FIREFOX="${ENABLE_FIREFOX:-false}"
export RESOLUTION="${RESOLUTION:-1280x800}"
export COLOR_DEPTH="${COLOR_DEPTH:-24}"
export DPI="${DPI:-96}"

mkdir -p /data "$WINEPREFIX/drive_c/Program Files/Kakao"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# 1. Sync KakaoTalk application files to persistent volume
KAKAO_TARGET_DIR="$WINEPREFIX/drive_c/Program Files/Kakao/KakaoTalk"
IMAGE_CHANGELOG="/opt/kakao/KakaoTalk/ChangeLogs_ko.md"
INSTALLED_CHANGELOG="$KAKAO_TARGET_DIR/ChangeLogs_ko.md"

get_kakao_version() {
  local changelog="$1"
  if [ -f "$changelog" ]; then
    grep -m 1 -oP '(?<=### )\d+\.\d+\.\d+' "$changelog" 2>/dev/null || echo "0.0.0"
  else
    echo "0.0.0"
  fi
}

if [ ! -d "$KAKAO_TARGET_DIR" ]; then
  echo "Initializing KakaoTalk files in $WINEPREFIX"
  cp -a /opt/kakao/KakaoTalk "$WINEPREFIX/drive_c/Program Files/Kakao/"
elif [ -f "$IMAGE_CHANGELOG" ] && [ -f "$INSTALLED_CHANGELOG" ]; then
  IMAGE_VER=$(get_kakao_version "$IMAGE_CHANGELOG")
  INSTALLED_VER=$(get_kakao_version "$INSTALLED_CHANGELOG")
  if [ "$IMAGE_VER" != "$INSTALLED_VER" ] && [ "$(printf '%s\n%s\n' "$IMAGE_VER" "$INSTALLED_VER" | sort -V | head -n 1)" = "$INSTALLED_VER" ]; then
    echo "Image KakaoTalk version ($IMAGE_VER) is newer than installed version ($INSTALLED_VER); updating binaries..."
    cp -a /opt/kakao/KakaoTalk/* "$KAKAO_TARGET_DIR/"
  else
    echo "Installed KakaoTalk version ($INSTALLED_VER) is up to date (image version: $IMAGE_VER). Skipping binary sync."
  fi
elif [ -d /opt/kakao/KakaoTalk ] && [ ! -f "$KAKAO_TARGET_DIR/KakaoTalk.exe" ]; then
  echo "KakaoTalk binaries missing in volume; copying from image..."
  cp -a /opt/kakao/KakaoTalk/* "$KAKAO_TARGET_DIR/"
fi

# 2. Initialize Wine prefix
if [ ! -f "$WINEPREFIX/.initialized" ]; then
  echo "Initializing Wine prefix at $WINEPREFIX"
  wineboot -u || true
  touch "$WINEPREFIX/.initialized"
fi

# 3. Apply Wine performance & Korean font tuning (ClearType, NanumGothic, DPI)
apply_wine_tuning() {
  local reg_file="/tmp/wine-tuning.reg"
  if [ -f /etc/wine/wine-tuning.reg ]; then
    cp /etc/wine/wine-tuning.reg "$reg_file"
  else
    cat <<'EOF' > "$reg_file"
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Control Panel\Desktop]
"FontSmoothing"="2"
"FontSmoothingOrientation"=dword:00000001
"FontSmoothingType"=dword:00000002
"FontSmoothingGamma"=dword:00000578

[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]
"Malgun Gothic"="NanumGothic"
"맑은 고딕"="NanumGothic"
"Gulim"="NanumGothic"
"굴림"="NanumGothic"
"Dotum"="NanumGothic"
"돋움"="NanumGothic"
"Batang"="NanumMyeongjo"
"바탕"="NanumMyeongjo"

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]
"Malgun Gothic"="NanumGothic"
"맑은 고딕"="NanumGothic"
"Gulim"="NanumGothic"
"굴림"="NanumGothic"
"Dotum"="NanumGothic"
"돋움"="NanumGothic"
"Batang"="NanumMyeongjo"
"바탕"="NanumMyeongjo"

[HKEY_CURRENT_USER\Software\Wine\WineDbg]
"ShowCrashDialog"=dword:00000000

[HKEY_CLASSES_ROOT\http\shell\open\command]
@="\"C:\\windows\\system32\\winebrowser.exe\" -nohome \"%1\""

[HKEY_CLASSES_ROOT\https\shell\open\command]
@="\"C:\\windows\\system32\\winebrowser.exe\" -nohome \"%1\""

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run]
"KakaoTalk"=-
EOF
  fi

  # Apply configurable DPI
  if [[ "$DPI" =~ ^[0-9]+$ ]]; then
    local dpi_hex
    dpi_hex=$(printf "%08x" "$DPI")
    cat <<EOF >> "$reg_file"

[HKEY_CURRENT_USER\Control Panel\Desktop]
"LogPixels"=dword:$dpi_hex
EOF
  fi

  echo "Applying Wine registry tuning (DPI: $DPI)..."
  wine regedit /S "$reg_file" 2>/dev/null || true
  rm -f "$reg_file"
}

apply_wine_tuning

# 4. Clean up any stale X locks
rm -f /tmp/.X100-lock /tmp/.X11-unix/X100 2>/dev/null || true

if ! [[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]]; then
  echo "Invalid RESOLUTION '$RESOLUTION', defaulting to 1280x800"
  RESOLUTION="1280x800"
fi

# 5. Start Xvfb virtual frame buffer
echo "Starting Xvfb on display $DISPLAY with resolution ${RESOLUTION}x${COLOR_DEPTH}..."
Xvfb "$DISPLAY" -screen 0 "${RESOLUTION}x${COLOR_DEPTH}" -ac +extension GLX +render -noreset &
xvfb_pid=$!

# Wait for Xvfb to become ready
for i in $(seq 1 30); do
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  echo "Error: Xvfb failed to initialize display $DISPLAY" >&2
  exit 1
fi

# 6. Start Window Manager & Panel
mkdir -p "$HOME/.config/openbox"
cp -f /etc/xdg/openbox/menu.xml "$HOME/.config/openbox/menu.xml" 2>/dev/null || true
cp -f /etc/xdg/openbox/rc.xml "$HOME/.config/openbox/rc.xml" 2>/dev/null || true
openbox >/tmp/openbox.log 2>&1 &
openbox_pid=$!

if [ "$ENABLE_FIREFOX" = "true" ]; then
  tint2 -c /etc/tint2/tint2rc >/tmp/tint2.log 2>&1 &
  tint2_pid=$!
else
  sed -e '/firefox\.desktop/d' \
      /etc/tint2/tint2rc > /tmp/tint2-kakao-only.rc
  tint2 -c /tmp/tint2-kakao-only.rc >/tmp/tint2.log 2>&1 &
  tint2_pid=$!
fi

# 7. Launch KakaoTalk
/usr/local/bin/run-kakao >/tmp/run-kakao.log 2>&1 &
kakao_pid=$!

# 8. Start x11vnc (bound to localhost for security, with optional password)
VNC_ARGS=(
  -display "$DISPLAY"
  -forever
  -shared
  -listen 127.0.0.1
  -rfbport 5900
  -xkb
  -noxdamage
  -repeat
  -cursor arrow
  -fixscreen V=3
  -wait 20
  -defer 20
)

if [ -n "${VNC_PASSWORD:-}" ]; then
  echo "Enabling VNC password authentication..."
  mkdir -pm 700 /tmp/.vnc
  echo "$VNC_PASSWORD" | x11vnc -storepasswd - /tmp/.vnc/passwd
  unset VNC_PASSWORD
  VNC_ARGS+=(-rfbauth /tmp/.vnc/passwd)
else
  VNC_ARGS+=(-nopw)
fi

x11vnc "${VNC_ARGS[@]}" >/tmp/x11vnc.log 2>&1 &
x11vnc_pid=$!

# 9. Start noVNC websockify proxy
echo "Starting noVNC websockify on port 14500..."
websockify \
  --web=/usr/share/novnc \
  0.0.0.0:14500 \
  127.0.0.1:5900 >/tmp/websockify.log 2>&1 &
websockify_pid=$!

# 10. Graceful shutdown handler
cleanup() {
  echo "Received shutdown signal. Stopping services gracefully..."
  # Cleanly flush Wine registry and wait for wineserver to exit
  wineserver -k 2>/dev/null || true
  wineserver -w 2>/dev/null || true
  # Terminate processes
  [ -n "${kakao_pid:-}" ] && kill -TERM "$kakao_pid" 2>/dev/null || true
  [ -n "${websockify_pid:-}" ] && kill -TERM "$websockify_pid" 2>/dev/null || true
  [ -n "${x11vnc_pid:-}" ] && kill -TERM "$x11vnc_pid" 2>/dev/null || true
  [ -n "${tint2_pid:-}" ] && kill -TERM "$tint2_pid" 2>/dev/null || true
  [ -n "${openbox_pid:-}" ] && kill -TERM "$openbox_pid" 2>/dev/null || true
  [ -n "${xvfb_pid:-}" ] && kill -TERM "$xvfb_pid" 2>/dev/null || true

  sleep 1
  exit 0
}

trap cleanup SIGTERM SIGINT

echo "KakaoTalk Web is ready at http://localhost:14500"

# Keep entrypoint alive to handle signals and supervise
wait "$websockify_pid" 2>/dev/null || wait
