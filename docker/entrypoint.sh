#!/usr/bin/env bash
# kakao-entrypoint - container supervisor for the KakaoTalk (Wine) desktop.
#
# This process is the single parent: it starts Xvfb, openbox, tint2, the KakaoTalk
# launcher, x11vnc, websockify (and best-effort xrdp), keeps their PIDs, and then
# runs the one monitor loop (monitor_loop) in this same shell. Because the monitor
# is the parent, it is the only writer of /data/runtime-state/ and the only owner of
# app relaunch (never two apps at once).
#
# Contracts (see doc/plans/kakaotalk-runtime-reliability.md, todo 2):
#   * Xvfb first + readiness check, THEN Wine init/tuning. `.initialized` only after a
#     successful wineboot.
#   * App liveness = an exact `KakaoTalk.exe` process (the launcher exiting is not the app exiting).
#   * Probe = /usr/local/bin/kakao-healthcheck (shared with Docker HEALTHCHECK).
#     Monitor: interval 10s, no overlapping probes, 3 consecutive failures, startup grace 90s.
#   * Recovery: diagnostics first; app relaunch only when the process is absent (same Wine
#     session, no `wineserver -k`); vnc/web: bounded TERM/KILL of that process only, relaunch
#     with the same args. Xvfb/openbox failure, or a layer not ready 90s after its one
#     recovery, escalates to a bounded full cleanup + non-zero exit (restart policy returns).
#   * ONE shared budget (3 automatic relaunches/full exits per 10 min) also guards the boot
#     paths. Over budget: stop acting, phase=blocked, wait. Reset: 10 min continuous ready,
#     manual-recovery marker, or a new image fingerprint. `docker stop` (SIGTERM) never counts.
#   * Exit/cleanup: trap on every exit keeps the exit code; Wine wait <=15s, total cleanup <=20s.
#   * Logs: phase/layer/reason/time/recovery-count only; never env dumps, passwords, tokens,
#     chat text or window titles.
#
# Testability: when this file is *sourced* (not executed) only the library below is
# defined. The clock is injectable (KAKAO_FAKE_NOW or redefine kakao_now) and every path
# is configurable via KAKAO_STATE_DIR, so budget_* / ready_streak_update can be unit-tested.

set -u

############################ configuration ############################

KAKAO_STATE_DIR="${KAKAO_STATE_DIR:-/data/runtime-state}"
BUDGET_MAX="${KAKAO_BUDGET_MAX:-3}"
BUDGET_WINDOW="${KAKAO_BUDGET_WINDOW:-600}"
READY_RESET_SECS="${KAKAO_READY_RESET_SECS:-600}"
MONITOR_INTERVAL="${KAKAO_MONITOR_INTERVAL:-10}"
FAIL_THRESHOLD="${KAKAO_FAIL_THRESHOLD:-3}"
STARTUP_GRACE="${KAKAO_STARTUP_GRACE:-90}"
LAYER_RECOVERY_DEADLINE="${KAKAO_LAYER_RECOVERY_DEADLINE:-90}"
X_READY_TIMEOUT="${KAKAO_X_READY_TIMEOUT:-30}"
WINEBOOT_TIMEOUT="${KAKAO_WINEBOOT_TIMEOUT:-180}"
# One shared boot deadline, counted from entrypoint start (= container start). Every boot step runs with
# min(its own cap, time remaining); exceeding it is a boot failure through fail_boot (same budget).
# It is measured on the monotonic uptime clock (the one `timeout`/`sleep` run on), not on wall time: a stepped or
# skewed wall clock must not make the step caps and the deadline disagree.
mono_s() { local up _; if read -r up _ </proc/uptime 2>/dev/null; then echo "${up%.*}"; else echo "$SECONDS"; fi; }
BOOT_DEADLINE="${KAKAO_BOOT_DEADLINE:-90}"
[[ "$BOOT_DEADLINE" =~ ^[0-9]+$ ]] || BOOT_DEADLINE=90
BOOT_T0=$(mono_s)
BOOT_EXPIRED=0
WINE_WAIT_MAX=15
CLEANUP_MAX=20
LOG_CAP=65536
HC_BIN="${KAKAO_HEALTHCHECK_BIN:-/usr/local/bin/kakao-healthcheck}"
UI_CHECK_EVERY=6
UI_STUCK_SECS="${KAKAO_UI_STUCK_SECS:-300}"  # window-less + connection-less this long => the app is stuck at start
UI_STUCK_MAX="${KAKAO_UI_STUCK_MAX:-2}"      # app restarts per container boot for ui_stuck; then report only

EXIT_BOOT_INIT=10   # wine prefix init failed
EXIT_BOOT_X=11      # Xvfb never became ready
EXIT_BOOT_SYNC=12   # KakaoTalk file sync failed
EXIT_BOOT_DEADLINE=13 # shared boot deadline exceeded
EXIT_RUNTIME=20     # full cleanup escalation from the monitor
EXIT_MANUAL_RESET=75

############################ globals ############################

BOOT_EPOCH=0
GRACE_UNTIL=0
STAGE=init
BLOCKED=0
ST_PHASE=starting
ST_LAYER=x
ST_REASON=boot
LAST_RESET=""
IMAGE_ID=""
UI_STATE=unknown
UI_WINDOWS=0
UI_UNCONF_SINCE=0
UI_STUCK_TRIES=0
UI_STUCK_GAVE_UP=0
READY_SINCE=0
MON_CONSEC=0
MON_LAST_LAYER=""
LAST_EVENT=""
CLEANED=0
BG_PID=""
PROBE_LINE=""
PROBE_RC=1
PROBE_OK=0
PROBE_PHASE=""
PROBE_LAYER=""
PROBE_REASON=""
DEAD_RC=""
xvfb_pid="" openbox_pid="" tint2_pid="" launcher_pid="" x11vnc_pid="" websockify_pid="" chansrv_pid="" xrdp_pid=""
declare -A REC_AT=()

############################ library: clock, files, budget ############################

kakao_now() { # injectable clock: KAKAO_FAKE_NOW (epoch seconds) overrides the real one
  if [ -n "${KAKAO_FAKE_NOW:-}" ]; then
    printf '%s\n' "$KAKAO_FAKE_NOW"
  else
    printf '%(%s)T\n' -1
  fi
}

nap() { sleep "$1" & wait $! 2>/dev/null; return 0; } # signal-interruptible sleep

atomic_write() { # <path>; stdin -> tmp + rename (parent only)
  local path=$1 tmp
  tmp="$path.tmp.$$"
  if cat >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

kv() { # <record> <key> -> value of key=value in a space separated record
  local rec=" $1 " k=$2 v
  v=${rec#* "$k"=}
  [ "$v" = "$rec" ] && return 1
  printf '%s' "${v%% *}"
}

BUDGET_FILE() { printf '%s/budget.log' "$KAKAO_STATE_DIR"; }

budget_recent() { # entries ("epoch kind reason") inside the window
  local f cutoff
  f=$(BUDGET_FILE)
  [ -f "$f" ] || return 0
  cutoff=$(($(kakao_now) - BUDGET_WINDOW))
  awk -v c="$cutoff" '$1 > c' "$f" 2>/dev/null
}

budget_count() { budget_recent | wc -l | tr -d ' '; }

budget_exhausted() { [ "$(budget_count)" -ge "$BUDGET_MAX" ]; }

# Shared by every automatic relaunch AND every automatic full exit/boot failure.
# Returns 1 (and records nothing) when the budget is already used up.
budget_consume() { # <kind> <reason>
  budget_exhausted && return 1
  { budget_recent; printf '%s %s %s\n' "$(kakao_now)" "$1" "$2"; } | atomic_write "$(BUDGET_FILE)"
}

budget_reset() { # <reason-token> [extra]: record in stdout + last-failure.log, then clear
  local n line; n=$(budget_count)
  : | atomic_write "$(BUDGET_FILE)"
  LAST_RESET="$(kakao_now):$1"
  line="ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) event=budget_reset reason=$1 cleared_entries=$n${2:+ $2}"
  printf '[kakao-runtime] %s\n' "$line"
  append_failure_log "$line"
}

# Called once per monitor tick. After READY_RESET_SECS of continuous ready the budget
# is reset (and a runtime block is lifted).
ready_streak_update() { # <1|0>
  local now; now=$(kakao_now)
  if [ "$1" = 1 ]; then
    [ "$READY_SINCE" -eq 0 ] && READY_SINCE=$now
    if [ $((now - READY_SINCE)) -ge "$READY_RESET_SECS" ]; then
      if [ "$(budget_count)" -gt 0 ] || [ "$BLOCKED" = 1 ]; then
        budget_reset "ready_${READY_RESET_SECS}s"
        BLOCKED=0
      fi
    fi
  else
    READY_SINCE=0
  fi
}

############################ library: logging and state ############################

append_failure_log() { # <line>; one file, capped at LOG_CAP bytes (keeps the newest half)
  local f="$KAKAO_STATE_DIR/last-failure.log" sz
  [ -d "$KAKAO_STATE_DIR" ] || return 0
  printf '%s\n' "$1" >>"$f" 2>/dev/null || return 0
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$LOG_CAP" ]; then
    tail -c $((LOG_CAP / 2)) "$f" 2>/dev/null | tail -n +2 | atomic_write "$f"
  fi
  return 0
}

rt_log() { # <phase> <layer> <reason> [extra]: stdout + last-failure.log (non-ready/starting only)
  local line
  line="ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) phase=$1 layer=$2 reason=$3 recovery_count=$(budget_count)${4:+ $4}"
  printf '[kakao-runtime] %s\n' "$line"
  case "$1" in ready|starting) ;; *) append_failure_log "$line" ;; esac
  return 0
}

rt_event() { # stdout-only lifecycle line without secrets
  printf '[kakao-runtime] ts=%s event=%s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:+ $2}"
}

write_state() { # atomic, parent only
  [ -d "$KAKAO_STATE_DIR" ] || return 0
  {
    printf 'phase=%s\nlayer=%s\nreason=%s\n' "$ST_PHASE" "$ST_LAYER" "$ST_REASON"
    printf 'ts=%s\nstage=%s\nboot_epoch=%s\ngrace_until=%s\nblocked=%s\n' "$(kakao_now)" "$STAGE" "$BOOT_EPOCH" "$GRACE_UNTIL" "$BLOCKED"
    printf 'recovery_count=%s\nbudget_max=%s\nbudget_window_s=%s\n' "$(budget_count)" "$BUDGET_MAX" "$BUDGET_WINDOW"
    printf 'monitor_pid=%s\nxvfb_pid=%s\nopenbox_pid=%s\nlauncher_pid=%s\nx11vnc_pid=%s\nwebsockify_pid=%s\n' \
      "$$" "$xvfb_pid" "$openbox_pid" "$launcher_pid" "$x11vnc_pid" "$websockify_pid"
    printf 'ui=%s\nui_windows=%s\nimage_id=%s\nlast_budget_reset=%s\n' "$UI_STATE" "$UI_WINDOWS" "$IMAGE_ID" "$LAST_RESET"
  } | atomic_write "$KAKAO_STATE_DIR/state"
  return 0
}

############################ library: process helpers ############################

pid_alive() { # <pid> [name-regex]: exists, not a zombie, optional exact comm match
  local pid=${1:-} k v name="" state=""
  [ -n "$pid" ] && [ -r "/proc/$pid/status" ] || return 1
  while IFS=$':\t ' read -r k v _; do
    case "$k" in Name) name=$v ;; State) state=$v ;; esac
  done <"/proc/$pid/status" 2>/dev/null
  case "$state" in Z|X|"") return 1 ;; esac
  if [ -n "${2:-}" ]; then
    [[ "$name" =~ ^($2)$ ]] || return 1
  fi
  return 0
}

stop_pid() { # <pid> [grace_s]: bounded CONT+TERM, then KILL. Never waits unboundedly.
  local pid=${1:-} grace=${2:-5} n=0
  pid_alive "$pid" || return 0
  kill -CONT "$pid" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
  while [ "$n" -lt $((grace * 5)) ]; do
    pid_alive "$pid" || return 0
    nap 0.2; n=$((n + 1))
  done
  kill -KILL "$pid" 2>/dev/null
  n=0
  while [ "$n" -lt 10 ]; do
    pid_alive "$pid" || return 0
    nap 0.2; n=$((n + 1))
  done
  return 1
}

run_bg() { # <limit_s> <cmd...>: bounded command that stays interruptible by SIGTERM
  local lim=$1; shift
  timeout -k 2 "$lim" "$@" &
  BG_PID=$!
  wait "$BG_PID"
  local rc=$?
  BG_PID=""
  return "$rc"
}

boot_left() { # whole seconds of the shared boot deadline that remain (never negative)
  local l=$((BOOT_DEADLINE - ($(mono_s) - BOOT_T0)))
  [ "$l" -lt 0 ] && l=0
  echo "$l"
}

boot_expired() { [ "$(boot_left)" -le 0 ]; }

boot_cap() { # <own_cap_s> -> min(own cap, remaining boot time); 0 means the deadline is used up
  awk -v a="$1" -v b="$(boot_left)" 'BEGIN { print (a + 0 < b + 0) ? a : b }'
}

boot_run() { # <own_cap_s> <cmd...>: run_bg bounded by min(own cap, remaining boot time)
  local own=$1 lim rc; shift
  lim=$(boot_cap "$own")
  if [ "$lim" = 0 ]; then BOOT_EXPIRED=1; return 124; fi # `timeout 0` would mean unlimited: never run
  run_bg "$lim" "$@"; rc=$?
  if [ "$rc" -ne 0 ] && boot_expired; then BOOT_EXPIRED=1; fi
  return "$rc"
}

layer_idx() { case "$1" in x) echo 0 ;; vnc) echo 1 ;; web) echo 2 ;; app) echo 3 ;; *) echo 9 ;; esac; }

############################ library: probe + diagnostics ############################

run_probe() { # one probe at a time (sequential in the monitor); sets PROBE_*
  local out=/tmp/kakao-probe.out
  : >"$out"
  # The redirect lives inside the child: a redirect on the run_bg call itself would also capture the output of a SIGTERM
  # handler (manual_stop / cleanup_done) that fires while run_bg waits.
  run_bg 14 sh -c 'exec "$0" >"$1" 2>/dev/null' "$HC_BIN" "$out"
  PROBE_RC=$?
  PROBE_LINE=$(head -n 1 "$out" 2>/dev/null)
  PROBE_PHASE=$(kv "$PROBE_LINE" phase) || PROBE_PHASE=""
  PROBE_LAYER=$(kv "$PROBE_LINE" layer) || PROBE_LAYER=""
  PROBE_REASON=$(kv "$PROBE_LINE" reason) || PROBE_REASON=""
  if [ -z "$PROBE_PHASE" ]; then
    PROBE_PHASE=degraded; PROBE_LAYER=x; PROBE_REASON=probe_no_record
  fi
  if [ "$PROBE_RC" -eq 0 ] && [ "$PROBE_PHASE" = ready ]; then PROBE_OK=1; else PROBE_OK=0; fi
}

diagnostics() { # <layer> <reason>: bounded, no cmdlines/env/titles
  local f="$KAKAO_STATE_DIR/last-failure.log"
  [ -d "$KAKAO_STATE_DIR" ] || return 0
  {
    printf -- '--- diagnostics ts=%s layer=%s reason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"
    printf 'probe: %s\n' "$PROBE_LINE"
    printf 'loadavg: %s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    printf 'mem_available_kb: %s\n' "$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)"
    printf 'data_free_kb: %s\n' "$(df -Pk /data 2>/dev/null | awk 'NR==2 {print $4}')"
    printf 'processes (pid stat etime comm):\n'
    timeout -k 1 3 ps -eo pid=,stat=,etime=,comm= 2>/dev/null | head -n 60
  } | while IFS= read -r line; do append_failure_log "$line"; done
  true
  return 0
}

ui_check() { # window count by class only; informational (UI-unconfirmed is never a restart reason)
  local n
  n=$(timeout -k 0.2 3 wmctrl -lx 2>/dev/null | awk 'tolower($3) ~ /kakaotalk/ {c++} END {print c+0}')
  UI_WINDOWS=${n:-0}
  if [ "$UI_WINDOWS" -gt 0 ] 2>/dev/null; then
    UI_STATE=confirmed
  else
    UI_STATE=unconfirmed
  fi
}

ui_net_established() { # ESTABLISHED TCP sockets to non-loopback peers, ignoring our own served ports (VNC 5900, noVNC 14500, RDP 3389)
  cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk '
    $4 == "01" {
      split($2, l, ":"); split($3, r, ":")
      lp = toupper(l[2]); rip = toupper(r[1])
      if (lp == "170C" || lp == "38A4" || lp == "0D3D") next
      if (rip == "0100007F" || rip == "00000000000000000000000001000000" || rip == "0000000000000000FFFF00000100007F") next
      c++
    } END { print c + 0 }'
}

# A logged-in app that is minimized to the tray has no visible window but holds a server connection; a login screen is
# a visible window. Only "no window AND no connection for UI_STUCK_SECS" means the app never came up (observed: the
# process idles forever at 6 threads with no window). Counts only: no titles, no chat data.
recover_ui_stuck() {
  local p
  [ "$BLOCKED" = 1 ] && return 0
  UI_STATE=stuck
  if [ "$UI_STUCK_TRIES" -ge "$UI_STUCK_MAX" ]; then
    if [ "$UI_STUCK_GAVE_UP" != 1 ]; then
      UI_STUCK_GAVE_UP=1
      rt_log degraded app ui_stuck_unrecovered "action=none tries=$UI_STUCK_TRIES"
    fi
    return 0
  fi
  diagnostics app ui_stuck
  if ! budget_consume app_relaunch ui_stuck; then
    enter_blocked app ui_stuck
    return 0
  fi
  UI_STUCK_TRIES=$((UI_STUCK_TRIES + 1))
  rt_log degraded app ui_stuck "action=restart_app tries=$UI_STUCK_TRIES windows=0 connections=0"
  for p in $(pgrep -x KakaoTalk.exe 2>/dev/null); do stop_pid "$p" 5; done
  relaunch_app
  UI_UNCONF_SINCE=0
  write_state
}

ui_stuck_check() { # after ui_check: tracks how long the app has had no window, then acts if it also has no connection
  local now
  if [ "$UI_STATE" = confirmed ]; then
    UI_UNCONF_SINCE=0; UI_STUCK_TRIES=0; UI_STUCK_GAVE_UP=0
    return 0
  fi
  now=$(kakao_now)
  [ "$UI_UNCONF_SINCE" -gt 0 ] || UI_UNCONF_SINCE=$now
  [ $((now - UI_UNCONF_SINCE)) -ge "$UI_STUCK_SECS" ] || return 0
  pgrep -x KakaoTalk.exe >/dev/null 2>&1 || return 0   # absent app is the hard-failure path's job
  [ "$(ui_net_established)" -gt 0 ] && return 0
  recover_ui_stuck
}

############################ service start helpers ############################

start_xvfb() {
  Xvfb "$DISPLAY" -screen 0 "${RESOLUTION}x${COLOR_DEPTH}" -ac +extension GLX +render -noreset >/tmp/xvfb.log 2>&1 &
  xvfb_pid=$!
}

wait_x_ready() { # bounded by min(X_READY_TIMEOUT, remaining boot time); fails fast if Xvfb dies
  local dl=$(($(mono_s) + $(boot_cap "$X_READY_TIMEOUT"))) l
  while :; do
    pid_alive "$xvfb_pid" || return 1
    l=$(boot_cap 3)
    if [ "$l" = 0 ]; then BOOT_EXPIRED=1; return 1; fi
    timeout -k 0.2 "$l" xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && return 0
    if [ "$(mono_s)" -ge "$dl" ]; then boot_expired && BOOT_EXPIRED=1; return 1; fi
    nap 0.2
  done
}

start_openbox() {
  mkdir -p "$HOME/.config/openbox"
  cp -f /etc/xdg/openbox/menu.xml "$HOME/.config/openbox/menu.xml" 2>/dev/null || true
  cp -f /etc/xdg/openbox/rc.xml "$HOME/.config/openbox/rc.xml" 2>/dev/null || true
  openbox >/tmp/openbox.log 2>&1 &
  openbox_pid=$!
}

start_tint2() {
  if [ "$ENABLE_FIREFOX" = "true" ]; then
    tint2 -c /etc/tint2/tint2rc >/tmp/tint2.log 2>&1 &
  else
    sed -e '/firefox\.desktop/d' /etc/tint2/tint2rc >/tmp/tint2-kakao-only.rc
    tint2 -c /tmp/tint2-kakao-only.rc >/tmp/tint2.log 2>&1 &
  fi
  tint2_pid=$!
}

launch_app() { # the only place that starts the launcher; callers guarantee KakaoTalk.exe is absent
  chmod +x /usr/local/bin/run-kakao 2>/dev/null || true
  rm -f /data/wineprefix/drive_c/users/root/AppData/Local/Kakao/KakaoTalk/.sentry-native/*.lock 2>/dev/null || true
  /usr/local/bin/run-kakao >>/tmp/run-kakao.log 2>&1 &
  launcher_pid=$!
}

build_vnc_args() {
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
    echo "$VNC_PASSWORD" | x11vnc -storepasswd - /tmp/.vnc/passwd >/dev/null 2>&1
    VNC_ARGS+=(-rfbauth /tmp/.vnc/passwd)
  else
    VNC_ARGS+=(-nopw)
  fi
}

start_x11vnc() { # same args on every (re)launch
  x11vnc "${VNC_ARGS[@]}" >>/tmp/x11vnc.log 2>&1 &
  x11vnc_pid=$!
}

start_websockify() {
  websockify \
    --web=/usr/share/novnc \
    0.0.0.0:14500 \
    127.0.0.1:5900 >>/tmp/websockify.log 2>&1 &
  websockify_pid=$!
}

configure_and_start_xrdp() {
  if ! command -v xrdp >/dev/null 2>&1; then
    return 0
  fi

  echo "Configuring and starting xrdp on port 3389..."
  rm -f /var/run/xrdp/xrdp.pid /run/xrdp/xrdp.pid /tmp/.xrdp/xrdp.pid 2>/dev/null || true
  mkdir -p /run/xrdp /run/xrdp/sockdir /tmp/.xrdp
  chmod 755 /run/xrdp /run/xrdp/sockdir /tmp/.xrdp

  local xrdp_ini="/etc/xrdp/xrdp.ini"
  if [ -f "$xrdp_ini" ]; then
    sed -i 's/^autorun=.*/autorun=KakaoTalk/' "$xrdp_ini" || true
    sed -i '/\[KakaoTalk\]/,$d' "$xrdp_ini" || true

    local vnc_pw_setting=""
    if [ -n "${VNC_PASSWORD:-}" ]; then
      vnc_pw_setting="password=${VNC_PASSWORD}"
    else
      vnc_pw_setting="password="
    fi

    cat <<EOF >> "$xrdp_ini"

[KakaoTalk]
name=KakaoTalk
lib=libvnc.so
ip=127.0.0.1
port=5900
username=na
$vnc_pw_setting
chansrvport=DISPLAY(100)
EOF
  fi

  DISPLAY="$DISPLAY" xrdp-chansrv >/tmp/xrdp-chansrv.log 2>&1 &
  chansrv_pid=$!

  nap 1
  # Ensure socket compatibility across different xrdp versions
  if [ -S /run/xrdp/sockdir/xrdp_chansrv_socket_100 ] && [ ! -e /tmp/.xrdp/xrdp_chansrv_socket_100 ]; then
    ln -sf /run/xrdp/sockdir/xrdp_chansrv_socket_100 /tmp/.xrdp/xrdp_chansrv_socket_100 2>/dev/null || true
  fi

  xrdp >/tmp/xrdp.log 2>&1 &
  xrdp_pid=$!
}

############################ boot: wine/app files ############################

get_kakao_version() {
  local changelog="$1"
  if [ -f "$changelog" ]; then
    grep -m 1 -oP '(?<=### )\d+\.\d+\.\d+' "$changelog" 2>/dev/null || echo "0.0.0"
  else
    echo "0.0.0"
  fi
}

sync_kakao_files() { # unchanged rules: copy when missing, update only when the image is newer
  local KAKAO_TARGET_DIR="$WINEPREFIX/drive_c/Program Files/Kakao/KakaoTalk"
  local IMAGE_CHANGELOG="/opt/kakao/KakaoTalk/ChangeLogs_ko.md"
  local INSTALLED_CHANGELOG="$KAKAO_TARGET_DIR/ChangeLogs_ko.md"
  local IMAGE_VER INSTALLED_VER
  if [ ! -d "$KAKAO_TARGET_DIR" ]; then
    echo "Initializing KakaoTalk files in $WINEPREFIX"
    boot_run 300 cp -a /opt/kakao/KakaoTalk "$WINEPREFIX/drive_c/Program Files/Kakao/"
  elif [ -f "$IMAGE_CHANGELOG" ] && [ -f "$INSTALLED_CHANGELOG" ]; then
    IMAGE_VER=$(get_kakao_version "$IMAGE_CHANGELOG")
    INSTALLED_VER=$(get_kakao_version "$INSTALLED_CHANGELOG")
    if [ "$IMAGE_VER" != "$INSTALLED_VER" ] && [ "$(printf '%s\n%s\n' "$IMAGE_VER" "$INSTALLED_VER" | sort -V | head -n 1)" = "$INSTALLED_VER" ]; then
      echo "Image KakaoTalk version ($IMAGE_VER) is newer than installed version ($INSTALLED_VER); updating binaries..."
      boot_run 300 cp -a /opt/kakao/KakaoTalk/* "$KAKAO_TARGET_DIR/"
    else
      echo "Installed KakaoTalk version ($INSTALLED_VER) is up to date (image version: $IMAGE_VER). Skipping binary sync."
    fi
  elif [ -d /opt/kakao/KakaoTalk ] && [ ! -f "$KAKAO_TARGET_DIR/KakaoTalk.exe" ]; then
    echo "KakaoTalk binaries missing in volume; copying from image..."
    boot_run 300 cp -a /opt/kakao/KakaoTalk/* "$KAKAO_TARGET_DIR/"
  fi
}

# The marker is created ONLY after wineboot succeeded; an existing prefix is never re-initialized.
init_wine_prefix() {
  [ -f "$WINEPREFIX/.initialized" ] && return 0
  echo "Initializing Wine prefix at $WINEPREFIX"
  # With Xvfb up (contract: X first) wineboot opens the Mono/Gecko download dialogs and hangs until
  # its own 300s boot timeout (rc 53, half-built prefix) because there is no network path. Neither
  # component is used by KakaoTalk, so they are disabled for this one init call only.
  boot_run "$WINEBOOT_TIMEOUT" env WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -u || return 1
  touch "$WINEPREFIX/.initialized"
}

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
  boot_run 60 wine regedit /S "$reg_file" 2>/dev/null || true
  rm -f "$reg_file"
  [ "$BOOT_EXPIRED" = 1 ] && return 1 # a registry tuning failure is tolerated, a spent boot deadline is not
  return 0
}

############################ budget at boot, blocked states ############################

# The container cannot read its own image ID; KAKAO_IMAGE_ID (if provided) wins, otherwise a
# fingerprint of the shipped scripts + Wine version + KakaoTalk.exe size/mtime stands in.
current_image_id() {
  if [ -n "${KAKAO_IMAGE_ID:-}" ]; then
    printf 'id:%s' "$KAKAO_IMAGE_ID"
    return
  fi
  {
    sha256sum /usr/local/bin/kakao-entrypoint /usr/local/bin/run-kakao "$HC_BIN" 2>/dev/null
    timeout -k 1 5 wine --version 2>/dev/null
    stat -c '%s %Y' /opt/kakao/KakaoTalk/KakaoTalk.exe 2>/dev/null
  } | sha256sum | cut -c1-16 | sed 's/^/fp:/'
}

check_manual_recovery() { # explicit manual recovery marker (written by the operator tool) resets the budget
  local m="$KAKAO_STATE_DIR/manual-recovery"
  [ -e "$m" ] || return 1
  rm -f "$m"
  budget_reset manual_recovery
  return 0
}

check_image_change() {
  local f="$KAKAO_STATE_DIR/image_id" old=""
  IMAGE_ID=$(current_image_id)
  [ -f "$f" ] && old=$(head -n 1 "$f" 2>/dev/null)
  if [ -n "$old" ] && [ "$old" != "$IMAGE_ID" ]; then
    budget_reset new_image "old=$old new=$IMAGE_ID"
  fi
  printf '%s\n' "$IMAGE_ID" | atomic_write "$f"
}

blocked_idle() { # boot-time block: nothing was started; wait for a manual-recovery marker or SIGTERM
  BLOCKED=1; STAGE=blocked; ST_PHASE=blocked; ST_LAYER=$1; ST_REASON=$2
  rt_log blocked "$1" "$2" "action=none hint=create_manual-recovery_marker_then_restart"
  while :; do
    write_state
    if check_manual_recovery; then
      rt_event manual_recovery_seen "action=exit_for_clean_boot"
      exit "$EXIT_MANUAL_RESET"
    fi
    nap "$MONITOR_INTERVAL"
  done
}

fail_boot() { # <exit_code> <layer> <reason>: boot paths count against the SAME budget
  local code=$1 layer=$2 reason=$3
  ST_PHASE=degraded; ST_LAYER=$layer; ST_REASON=$reason
  diagnostics "$layer" "$reason"
  if budget_consume boot_failure "$reason"; then
    rt_log degraded "$layer" "$reason" "action=exit code=$code"
    write_state
    exit "$code"
  fi
  blocked_idle "$layer" "$reason"
}

boot_fail() { # <exit_code> <layer> <reason>: fail_boot, except that a spent shared boot deadline always wins
  if [ "$BOOT_EXPIRED" = 1 ] || boot_expired; then
    local extra="step=$3 elapsed_s=$(($(mono_s) - BOOT_T0)) limit_s=$BOOT_DEADLINE"
    rt_event boot_deadline "$extra"
    append_failure_log "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) event=boot_deadline $extra"
    fail_boot "$EXIT_BOOT_DEADLINE" "$2" boot_deadline_exceeded
  fi
  fail_boot "$@"
}

boot_gate() { # <layer> <step>: between boot steps
  if boot_expired; then BOOT_EXPIRED=1; boot_fail "$EXIT_BOOT_DEADLINE" "$1" "gate_$2"; fi
  return 0
}

############################ monitor: recovery actions ############################

enter_blocked() { # <layer> <reason>: runtime budget exhausted; stop acting
  BLOCKED=1
  ST_PHASE=blocked; ST_LAYER=$1; ST_REASON=$2
  LAST_EVENT="blocked/$1/$2"   # the next monitor tick must not log the same blocked transition a second time
  rt_log blocked "$1" "$2" "action=none budget_exhausted=1 hint=manual-recovery_marker_then_restart"
  write_state
}

escalate_full() { # <layer> <reason>: bounded full cleanup + non-zero exit; restart policy brings it back
  local layer=$1 reason=$2
  [ "$BLOCKED" = 1 ] && return 0
  diagnostics "$layer" "$reason"
  if ! budget_consume full_exit "$reason"; then
    enter_blocked "$layer" "$reason"
    return 0
  fi
  ST_PHASE=degraded; ST_LAYER=$layer; ST_REASON=$reason
  rt_log degraded "$layer" "$reason" "action=full_cleanup_exit code=$EXIT_RUNTIME"
  write_state
  exit "$EXIT_RUNTIME"
}

relaunch_vnc() { stop_pid "$x11vnc_pid" 5; start_x11vnc; }
relaunch_web() { stop_pid "$websockify_pid" 5; start_websockify; }
relaunch_app() {
  # Serialization guard: this is the only relaunch path and it never starts a second app.
  if pgrep -x KakaoTalk.exe >/dev/null 2>&1; then
    rt_event app_relaunch_skipped "reason=process_present"
    return 0
  fi
  stop_pid "$launcher_pid" 3 # stuck launcher without an app; same Wine session is kept (no wineserver -k)
  # A dead app instance leaves the window manager in a state where the NEXT instance's top-level window is
  # never mapped (process healthy, login screen invisible; reproduced: a fresh openbox process fixes it,
  # `openbox --restart` and cleaning root properties do not). openbox is stateless here, so it is respawned
  # (new PID, bounded) right before every app relaunch; Xvfb/x11vnc/websockify/tint2 are untouched.
  stop_pid "$openbox_pid" 3
  start_openbox
  nap 1
  launch_app
}

recover_layer() { # <layer> <hard|soft> <reason> [extra]
  local layer=$1 kind=$2 reason=$3 extra=${4:-} now started
  [ "$BLOCKED" = 1 ] && return 0
  now=$(kakao_now)
  started=${REC_AT[$layer]:-}
  if [ -n "$started" ]; then
    # one recovery was already attempted for this layer and it is not ready again yet
    if [ "$kind" = hard ] || [ $((now - started)) -ge "$LAYER_RECOVERY_DEADLINE" ]; then
      escalate_full "$layer" "${layer}_not_recovered:$reason"
    fi
    return 0
  fi
  diagnostics "$layer" "$reason"
  if ! budget_consume "${layer}_relaunch" "$reason"; then
    enter_blocked "$layer" "$reason"
    return 0
  fi
  ST_PHASE=degraded; ST_LAYER=$layer; ST_REASON=$reason
  rt_log degraded "$layer" "$reason" "action=relaunch_${layer} kind=$kind${extra:+ $extra}"
  "relaunch_$layer"
  REC_AT[$layer]=$(kakao_now)
  MON_CONSEC=0
  write_state
}

check_hard() { # parent-held PIDs: process death is unambiguous, no debounce
  if ! pid_alive "$xvfb_pid" Xvfb; then
    wait "$xvfb_pid" 2>/dev/null; DEAD_RC=$?
    escalate_full x xvfb_process_exited
    return
  fi
  if ! pid_alive "$openbox_pid" openbox; then
    wait "$openbox_pid" 2>/dev/null; DEAD_RC=$?
    escalate_full x openbox_process_exited
    return
  fi
  if ! pid_alive "$x11vnc_pid" x11vnc; then
    wait "$x11vnc_pid" 2>/dev/null; DEAD_RC=$?
    recover_layer vnc hard x11vnc_process_exited "exit_status=$DEAD_RC"
  fi
  if ! pid_alive "$websockify_pid" 'websockify|python3?'; then
    wait "$websockify_pid" 2>/dev/null; DEAD_RC=$?
    recover_layer web hard websockify_process_exited "exit_status=$DEAD_RC"
  fi
  # app: the launcher exiting is NOT the app exiting; look for the exact KakaoTalk.exe process
  if ! pgrep -x KakaoTalk.exe >/dev/null 2>&1 && ! pid_alive "$launcher_pid"; then
    wait "$launcher_pid" 2>/dev/null; DEAD_RC=$?
    recover_layer app hard app_process_absent "launcher_exit_status=$DEAD_RC"
  fi
}

reconcile_recoveries() { # forget a layer's pending recovery once the probe got past it
  local l
  for l in "${!REC_AT[@]}"; do
    if [ "$PROBE_OK" = 1 ] || [ "$(layer_idx "$PROBE_LAYER")" -gt "$(layer_idx "$l")" ]; then
      unset 'REC_AT[$l]'
    fi
  done
}

monitor_tick() {
  local t0=$SECONDS now ev
  run_probe
  now=$(kakao_now)
  reconcile_recoveries
  ready_streak_update "$PROBE_OK"

  if [ "$PROBE_OK" = 1 ]; then
    MON_CONSEC=0; MON_LAST_LAYER=""
    ST_PHASE=ready; ST_LAYER=app; ST_REASON=ok
    MON_TICKS=$((${MON_TICKS:-0} + 1))
    if [ $((MON_TICKS % UI_CHECK_EVERY)) -eq 1 ]; then
      local prev=$UI_STATE
      ui_check
      if [ "$UI_STATE" = unconfirmed ] && { [ "$prev" = confirmed ] || [ "$prev" = unknown ]; }; then
        rt_event ui_unconfirmed "layer=app reason=ui_unconfirmed windows=0 action=none"
      fi
      ui_stuck_check
    fi
  else
    if [ "$PROBE_LAYER" = "$MON_LAST_LAYER" ]; then
      MON_CONSEC=$((MON_CONSEC + 1))
    else
      MON_CONSEC=1; MON_LAST_LAYER=$PROBE_LAYER
    fi
    ST_PHASE=$PROBE_PHASE; ST_LAYER=$PROBE_LAYER; ST_REASON=$PROBE_REASON
  fi

  ev="$ST_PHASE/$ST_LAYER/$ST_REASON"
  if [ "$ev" != "$LAST_EVENT" ]; then
    LAST_EVENT=$ev
    rt_log "$ST_PHASE" "$ST_LAYER" "$ST_REASON" "consecutive_failures=$MON_CONSEC"
  fi
  write_state

  if [ "$BLOCKED" = 1 ]; then
    # blocked: no automatic action; only a manual-recovery marker (or 10 min ready) lifts it
    if check_manual_recovery; then
      rt_event manual_recovery_seen "action=exit_for_clean_boot"
      exit "$EXIT_MANUAL_RESET"
    fi
    return 0
  fi

  check_hard
  [ "$PROBE_OK" = 1 ] && return 0
  [ "$BLOCKED" = 1 ] && return 0

  # soft failures: process alive but a layer does not answer; only after grace and N consecutive ticks
  if [ "$now" -ge "$GRACE_UNTIL" ] && [ "$MON_CONSEC" -ge "$FAIL_THRESHOLD" ]; then
    case "$PROBE_LAYER" in
      x) escalate_full x "probe_${PROBE_REASON}" ;;
      vnc) recover_layer vnc soft "probe_${PROBE_REASON}" ;;
      web) recover_layer web soft "probe_${PROBE_REASON}" ;;
      app) recover_layer app soft "probe_${PROBE_REASON}" ;;
    esac
  fi
  return 0
}

monitor_loop() {
  local t0 left
  while :; do
    t0=$SECONDS
    monitor_tick
    left=$((MONITOR_INTERVAL - (SECONDS - t0)))
    [ "$left" -gt 0 ] && nap "$left"
  done
}

############################ shutdown ############################

stop_wine() { # bounded: <=WINE_WAIT_MAX seconds, never an unbounded `wineserver -w`
  local wdl=$((SECONDS + WINE_WAIT_MAX))
  [ -n "$launcher_pid" ] && kill -TERM "$launcher_pid" 2>/dev/null
  if pgrep -x wineserver >/dev/null 2>&1; then
    timeout -k 1 5 wineserver -k >/dev/null 2>&1 || true
  fi
  while { pgrep -x wineserver >/dev/null 2>&1 || pgrep -x KakaoTalk.exe >/dev/null 2>&1; } && [ "$SECONDS" -lt "$wdl" ]; do
    nap 0.2
  done
  if pgrep -x wineserver >/dev/null 2>&1 || pgrep -x KakaoTalk.exe >/dev/null 2>&1; then
    pkill -KILL -x KakaoTalk.exe 2>/dev/null
    pkill -KILL -x wineserver 2>/dev/null
  fi
}

cleanup_all() { # bounded total <= CLEANUP_MAX; safe to call twice
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  trap '' TERM INT
  local start=$SECONDS dl=$((SECONDS + CLEANUP_MAX)) p pids
  STAGE=stopping
  write_state
  [ -n "$BG_PID" ] && kill -TERM "$BG_PID" 2>/dev/null
  stop_wine
  pids=("$xrdp_pid" "$chansrv_pid" "$websockify_pid" "$x11vnc_pid" "$tint2_pid" "$openbox_pid" "$xvfb_pid")
  for p in "${pids[@]}"; do
    [ -n "$p" ] && kill -CONT "$p" 2>/dev/null
    [ -n "$p" ] && kill -TERM "$p" 2>/dev/null
  done
  while [ "$SECONDS" -lt "$((dl - 1))" ]; do
    local any=0
    for p in "${pids[@]}"; do
      pid_alive "$p" && any=1
    done
    [ "$any" = 0 ] && break
    nap 0.2
  done
  for p in "${pids[@]}"; do
    pid_alive "$p" && kill -KILL "$p" 2>/dev/null
  done
  rt_event cleanup_done "elapsed_s=$((SECONDS - start))"
  return 0
}

on_exit() {
  local rc=$?
  cleanup_all
  exit "$rc"
}

on_signal() { # manual `docker stop`: never counted against the budget, never restarted by us
  rt_event manual_stop "signal=$1 counted=0"
  exit 0
}

############################ main ############################

main() {
  trap on_exit EXIT
  trap 'on_signal TERM' TERM
  trap 'on_signal INT' INT

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
  mkdir -p "$KAKAO_STATE_DIR" && chmod 700 "$KAKAO_STATE_DIR"

  BOOT_EPOCH=$(kakao_now)
  STAGE=init
  ST_PHASE=starting; ST_LAYER=x; ST_REASON=boot
  # clear a stale block flag from the previous run: blocked is recomputed below
  check_manual_recovery || true
  check_image_change
  write_state
  rt_event boot "image=$IMAGE_ID budget_used=$(budget_count)/$BUDGET_MAX"

  # Budget check on the boot path: a failing init/X boot loop must stop here.
  if budget_exhausted; then
    blocked_idle x budget_exhausted_at_boot
  fi

  if ! [[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "Invalid RESOLUTION '$RESOLUTION', defaulting to 1280x800"
    RESOLUTION="1280x800"
  fi

  # 1. Xvfb first and verify readiness BEFORE any Wine work.
  rm -f /tmp/.X100-lock /tmp/.X11-unix/X100 2>/dev/null || true
  echo "Starting Xvfb on display $DISPLAY with resolution ${RESOLUTION}x${COLOR_DEPTH}..."
  start_xvfb
  if ! wait_x_ready; then
    echo "Error: Xvfb failed to initialize display $DISPLAY" >&2
    boot_fail "$EXIT_BOOT_X" x xvfb_not_ready
  fi
  write_state

  # 2. Window manager and panel BEFORE any Wine work (same order as the pre-reliability runtime):
  #    wineboot/regedit/wineserver/explorer must find openbox already managing the display.
  start_openbox
  start_tint2

  # 3. KakaoTalk files, then Wine prefix init (marker only after success), then tuning.
  sync_kakao_files || boot_fail "$EXIT_BOOT_SYNC" app kakao_sync_failed
  boot_gate app after_sync
  init_wine_prefix || boot_fail "$EXIT_BOOT_INIT" app wine_init_failed
  apply_wine_tuning || boot_fail "$EXIT_BOOT_INIT" app wine_tuning_deadline
  boot_gate app after_tuning

  # 4. App, VNC, web, rdp.
  launch_app
  build_vnc_args
  start_x11vnc
  start_websockify
  configure_and_start_xrdp
  boot_gate vnc after_services

  STAGE=running
  GRACE_UNTIL=$(($(kakao_now) + STARTUP_GRACE))
  ST_PHASE=starting; ST_LAYER=vnc; ST_REASON=startup
  write_state
  echo "KakaoTalk Web is up at http://localhost:14500 (readiness: kakao-healthcheck)"
  echo "KakaoTalk RDP is up at localhost:13389"

  monitor_loop
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
