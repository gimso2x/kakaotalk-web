#!/usr/bin/env bash
# kakaoctl.sh - operator tool for the KakaoTalk container.
#
# Usage: scripts/kakaoctl.sh <status|diagnose|restart> [--project <name>] [--container <name>]
#   status     read-only: docker state/health, image ID, kakao-healthcheck record (phase/layer/reason),
#              runtime-state (recovery budget, last reset, blocked flag)
#   diagnose   read-only: status + process names, last-failure.log tail, recent [kakao-runtime] log lines
#   restart    explicit manual recovery: write a small diagnose snapshot, create the manual-recovery
#              marker (resets the recovery budget at the next boot), then `docker restart`.
#              The data volume, Wine prefix, .initialized marker and app data are never touched.
#
# Defaults: --project kakaotalk-web, --container kakaotalk-wine.
# The target is validated first: the container must exist and carry the compose project label
# com.docker.compose.project == --project; otherwise the command is REFUSED (exit 3) before anything runs.
#
# Secrets: the container configuration is never dumped and no variables are listed; only
# fixed, non-secret fields (queried one by one) and our own runtime-state records are printed.
#
# Exit codes: 0 ok | 3 refused (missing container / project mismatch) | 64 usage |
#   any other non-zero code is the failing docker command's own exit code, propagated unchanged.
#
# Limit: "ready" means X, VNC, web and the KakaoTalk.exe process answer. A frozen or blank KakaoTalk UI
# is NOT detected automatically: use `restart`. If only the window is hidden, the existing runner
# raises it: docker exec <container> run-kakao

set -uo pipefail

PROJECT=kakaotalk-web
CONTAINER=kakaotalk-wine
STATE_DIR=/data/runtime-state
HC_BIN=/usr/local/bin/kakao-healthcheck
EX_REFUSED=3
EX_USAGE=64

say() { printf '%s\n' "$*"; }
err() { printf 'kakaoctl: %s\n' "$*" >&2; }
refuse() { err "REFUSED: $*"; exit "$EX_REFUSED"; }
usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | cut -c3-; }
usage_err() { err "$*"; usage >&2; exit "$EX_USAGE"; }
# defence in depth: anything shaped like name=value for a secret-looking name is masked
redact() { sed -E 's/([A-Za-z_]*(password|passwd|secret|token))=[^[:space:]]*/\1=<redacted>/Ig'; }
cexec() { timeout 20 docker exec "$CONTAINER" "$@"; }

############################ target validation ############################

D_STATUS=""; D_HEALTH=""; D_RESTARTS=""; D_STARTED=""; D_EXIT=""; D_IMAGE=""; D_IMGREF=""

resolve_target() {
  local fmt out rc label
  fmt='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}|{{.State.ExitCode}}|{{.Image}}|{{.Config.Image}}|{{index .Config.Labels "com.docker.compose.project"}}'
  out=$(docker inspect --type container --format "$fmt" "$CONTAINER" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    case $out in
      *[Nn]o\ such*) refuse "container '$CONTAINER' does not exist" ;;
    esac
    err "docker inspect failed (exit $rc): ${out%%$'\n'*}"
    exit "$rc"
  fi
  IFS='|' read -r D_STATUS D_HEALTH D_RESTARTS D_STARTED D_EXIT D_IMAGE D_IMGREF label <<<"$out"
  [ "$label" = "$PROJECT" ] \
    || refuse "container '$CONTAINER' belongs to compose project '${label:-<none>}', not '$PROJECT'"
}

############################ reporting ############################

print_status() {
  local rec prc st g max win bl now ep kind reason age used=0 last="" entries="" marker sage
  say "target:   project=$PROJECT container=$CONTAINER"
  say "docker:   status=$D_STATUS health=$D_HEALTH restart_count=$D_RESTARTS exit_code=$D_EXIT started_at=$D_STARTED"
  say "image:    id=$D_IMAGE ref=$D_IMGREF"
  if [ "$D_STATUS" != running ]; then
    say "runtime:  unavailable (container is not running)"
    return 0
  fi
  if cexec test -x "$HC_BIN" 2>/dev/null; then
    rec=$(cexec "$HC_BIN" 2>/dev/null); prc=$?
    rec=$(printf '%s' "$rec" | head -n 1 | redact)
    case $rec in
      phase=*) say "probe:    $rec (exit=$prc)" ;;
      *) say "probe:    no record (exit=$prc)" ;;
    esac
  else
    say "probe:    unavailable (kakao-healthcheck is not in this image: pre-self-healing build)"
  fi
  st=$(cexec cat "$STATE_DIR/state" 2>/dev/null) || st=""
  if [ -z "$st" ]; then
    say "runtime:  no runtime-state (image without the self-healing monitor, or not written yet)"
    return 0
  fi
  g() { printf '%s\n' "$st" | sed -n "s/^$1=//p" | tail -n 1; }
  max=$(g budget_max); win=$(g budget_window_s)
  sage=$(( $(date +%s) - $(g ts | grep -E '^[0-9]+$' || echo 0) ))
  say "runtime:  phase=$(g phase) layer=$(g layer) reason=$(g reason) stage=$(g stage) blocked=$(g blocked) ui=$(g ui) ui_windows=$(g ui_windows) state_age_s=$sage$([ "$sage" -gt 60 ] && echo ' STALE(no monitor is updating this record)')" | redact
  say "monitor:  recovery_count=$(g recovery_count)/${max:-?} window_s=${win:-?} last_budget_reset=$(g last_budget_reset) image_fingerprint=$(g image_id)" | redact
  bl=$(cexec cat "$STATE_DIR/budget.log" 2>/dev/null) || bl=""
  now=$(date +%s)
  while read -r ep kind reason; do
    [[ $ep =~ ^[0-9]+$ ]] || continue
    age=$((now - ep))
    [ "$age" -le "${win:-600}" ] || continue
    used=$((used + 1))
    last="$kind $reason (${age}s ago)"
    entries+="           - ${age}s ago: $kind $reason"$'\n'
  done <<<"$bl"
  say "budget:   used_in_window=$used/${max:-?}"
  [ -n "$entries" ] && printf '%s' "$entries" | redact
  say "recovery: last_automatic_action=${last:-none}"
  if cexec test -e "$STATE_DIR/manual-recovery" 2>/dev/null; then marker=pending; else marker=absent; fi
  say "          manual_recovery_marker=$marker"
  if [ "$(g phase)" = blocked ] || [ "$(g blocked)" = 1 ]; then
    say "hint:     automatic recovery is stopped (budget exhausted). Reset it explicitly: kakaoctl.sh restart --project $PROJECT --container $CONTAINER"
  fi
}

failure_log_tail() { # <lines>
  local out
  out=$(cexec tail -n "$1" "$STATE_DIR/last-failure.log" 2>/dev/null | redact)
  if [ -n "$out" ]; then printf '%s\n' "$out"; else say "(empty or absent)"; fi
}

print_diagnose() {
  say "== kakaoctl diagnose =="
  print_status
  [ "$D_STATUS" = running ] || return 0
  say ""
  say "--- processes (pid state comm; no arguments) ---"
  cexec sh -c 'for p in /proc/[0-9]*; do c=$(cat "$p/comm" 2>/dev/null) || continue; s=$(sed -n "s/^State:[[:space:]]*\(.\).*/\1/p" "$p/status" 2>/dev/null); echo "${p#/proc/} $s $c"; done' 2>/dev/null \
    | head -n 60 | redact
  say ""
  say "--- last-failure.log (tail 30) ---"
  failure_log_tail 30
  say ""
  say "--- recent [kakao-runtime] container log lines (tail 15) ---"
  timeout 30 docker logs --tail 400 "$CONTAINER" 2>&1 | grep -a '\[kakao-runtime\]' | tail -n 15 | redact
  say ""
  say "note: ready = X, VNC, web and the KakaoTalk.exe process answer. A frozen UI is not detected automatically:"
  say "      use 'kakaoctl.sh restart'. A merely hidden window is raised by: docker exec $CONTAINER run-kakao"
}

############################ commands ############################

cmd_status() {
  say "== kakaoctl status =="
  print_status
}

cmd_restart() {
  local snap rc
  say "== kakaoctl restart: project=$PROJECT container=$CONTAINER =="
  if [ "$D_STATUS" != running ]; then
    err "container is not running: snapshot and recovery marker skipped"
  elif ! cexec test -d "$STATE_DIR" 2>/dev/null; then
    err "no $STATE_DIR (image without the self-healing monitor): snapshot and recovery marker skipped"
  else
    snap=$({
      say "# kakaoctl restart snapshot ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      print_status
      say "--- last-failure.log (tail 20) ---"
      failure_log_tail 20
    })
    timeout 20 docker exec -i "$CONTAINER" sh -c 'cat >"$1.tmp" && mv -f "$1.tmp" "$1"' _ "$STATE_DIR/manual-restart.snapshot" <<<"${snap:0:8000}"
    rc=$?
    if [ "$rc" -ne 0 ]; then err "could not write the diagnose snapshot (exit $rc); not restarting"; exit "$rc"; fi
    say "snapshot: $STATE_DIR/manual-restart.snapshot written"
    cexec sh -c ': >"$1"' _ "$STATE_DIR/manual-recovery"
    rc=$?
    if [ "$rc" -ne 0 ]; then err "could not create the manual-recovery marker (exit $rc); not restarting"; exit "$rc"; fi
    say "marker:   $STATE_DIR/manual-recovery created (budget is reset at boot)"
  fi
  timeout 180 docker restart "$CONTAINER"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    err "docker restart failed (exit $rc)"
    cexec rm -f "$STATE_DIR/manual-recovery" >/dev/null 2>&1 || true
    exit "$rc"
  fi
  say "restarted: $CONTAINER. Check progress with: kakaoctl.sh status --project $PROJECT --container $CONTAINER"
}

############################ main ############################

CMD=""
while [ $# -gt 0 ]; do
  case $1 in
    --project) [ $# -ge 2 ] || usage_err "--project needs a value"; PROJECT=$2; shift 2 ;;
    --project=*) PROJECT=${1#*=}; shift ;;
    --container) [ $# -ge 2 ] || usage_err "--container needs a value"; CONTAINER=$2; shift 2 ;;
    --container=*) CONTAINER=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    status|diagnose|restart) [ -z "$CMD" ] || usage_err "only one command allowed"; CMD=$1; shift ;;
    *) usage_err "unknown argument: $1" ;;
  esac
done
[ -n "$CMD" ] || usage_err "missing command"
[[ $PROJECT =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || usage_err "invalid --project value"
[[ $CONTAINER =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || usage_err "invalid --container value"
command -v docker >/dev/null 2>&1 || { err "docker not found"; exit 127; }

resolve_target
case $CMD in
  status) cmd_status ;;
  diagnose) print_diagnose ;;
  restart) cmd_restart ;;
esac
