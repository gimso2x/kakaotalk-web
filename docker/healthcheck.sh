#!/usr/bin/env bash
# kakao-healthcheck - the ONE probe shared by the Docker HEALTHCHECK and the
# in-container monitor (docker/entrypoint.sh).
#
# Layers, checked in this order; the first failing layer is reported:
#   x    X round-trip:        timeout 3 xdpyinfo
#   vnc  loopback RFB banner: bash /dev/tcp 127.0.0.1:5900, first 12 bytes must start with "RFB 003."
#   web  HTTP GET:            wget (timeout 3) http://127.0.0.1:14500/
#   app  process:             exact process name KakaoTalk.exe (not the launcher)
#
# Output: exactly ONE machine-readable record on stdout (space separated key=value):
#   phase=starting|ready|degraded|blocked layer=x|vnc|web|app reason=<token> ts=<utc> probe_ms=<n> recovery_count=<n>
# For phase=ready, layer is the last layer verified (app) and reason=ok.
# Exit status: 0 only for ready, 1 otherwise. Total runtime is bounded: at most three
# steps of <=3.2s each (timeout -k 0.2 3), well under the 12s ceiling.
#
# This is NOT a login/UI responsiveness guarantee: ready means the four layers answer.
# Nothing here reads window titles, chat data, environment dumps or tokens.
#
# Phase semantics when a layer fails (state is written by the entrypoint only; read-only here):
#   blocked   state file says blocked=1 (recovery budget exhausted; automatic actions stopped)
#   starting  stage!=running (init) or now < grace_until (startup grace)
#   degraded  otherwise

set -u

STATE_DIR="${KAKAO_STATE_DIR:-/data/runtime-state}"
STATE_FILE="$STATE_DIR/state"
export DISPLAY="${DISPLAY:-:100}"
VNC_PORT="${KAKAO_VNC_PORT:-5900}"
WEB_PORT="${KAKAO_WEB_PORT:-14500}"
STEP_TIMEOUT=3

state_get() { # <key> -> last value in the state file, empty when absent
  [ -r "$STATE_FILE" ] || return 0
  grep -m1 "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2-
}

START_MS=${EPOCHREALTIME/./}
START_MS=$((START_MS / 1000))

emit() { # <phase> <layer> <reason>
  local now_ms=${EPOCHREALTIME/./}
  now_ms=$((now_ms / 1000))
  printf 'phase=%s layer=%s reason=%s ts=%s probe_ms=%s recovery_count=%s\n' \
    "$1" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((now_ms - START_MS))" "$(state_get recovery_count || true)"
}

fail() { # <layer> <reason>
  local phase=degraded now stage grace
  now=$(printf '%(%s)T' -1)
  stage=$(state_get stage)
  grace=$(state_get grace_until)
  if [ "$(state_get blocked)" = 1 ]; then
    phase=blocked
  elif [ "$stage" != running ] || { [ -n "$grace" ] && [ "$now" -lt "$grace" ] 2>/dev/null; }; then
    phase=starting
  fi
  emit "$phase" "$1" "$2"
  exit 1
}

# --- x: real X round-trip -------------------------------------------------------
timeout -k 0.2 "$STEP_TIMEOUT" xdpyinfo >/dev/null 2>&1
rc=$?
case "$rc" in
  0) ;;
  124|137) fail x x_timeout ;;
  *) fail x x_unavailable ;;
esac

# --- vnc: RFB banner on loopback ---------------------------------------------------
banner=$(timeout -k 0.2 "$STEP_TIMEOUT" bash -c '
  export LC_ALL=C
  { exec 3<>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null || exit 2
  # The banner counts only when read itself succeeded with exactly 12 bytes starting "RFB 003.".
  IFS= read -r -N 12 -t 2.5 b <&3 || exit 3
  [ "${#b}" -eq 12 ] || exit 3
  case "$b" in "RFB 003."*) ;; *) exit 4 ;; esac
  printf "%s" "$b"
' _ "$VNC_PORT" 2>/dev/null)
rc=$?
case "$rc" in
  0) ;;
  2) fail vnc vnc_connect_failed ;;
  3) fail vnc vnc_short_banner ;;
  4) fail vnc vnc_bad_banner ;;
  124|137) fail vnc vnc_banner_timeout ;;
  *) fail vnc vnc_probe_error ;;
esac
if [ -z "$banner" ]; then
  fail vnc vnc_no_banner
fi
case "$banner" in
  "RFB 003."*) ;;
  *) fail vnc vnc_bad_banner ;;
esac

# --- web: HTTP GET -----------------------------------------------------------------------
timeout -k 0.2 "$STEP_TIMEOUT" wget -q -T "$STEP_TIMEOUT" -t 1 -O /dev/null "http://127.0.0.1:${WEB_PORT}/" >/dev/null 2>&1
rc=$?
case "$rc" in
  0) ;;
  124|137) fail web web_timeout ;;
  *) fail web web_http_error ;;
esac

# --- app: the exact KakaoTalk.exe process (launcher exit is not app exit) ---------------
if ! pgrep -x KakaoTalk.exe >/dev/null 2>&1; then
  fail app app_process_absent
fi

emit ready app ok
exit 0
