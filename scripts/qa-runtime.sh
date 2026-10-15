#!/usr/bin/env bash
# qa-runtime.sh - isolated QA driver for the KakaoTalk runtime reliability work.
#
# Everything here operates ONLY on the QA stack declared in docker-compose.qa.yml
# (project kakao-reliability-qa, container kakaotalk-reliability-qa, QA-only volume,
# ports 127.0.0.1:24500/23389). Production (kakaotalk-web / kakaotalk-wine /
# kakaotalk-web_kakao-wine-data / 14500 / 13389 / kakaotalk-wine:local) is only
# ever READ (docker inspect, sha256sum of two script files).
#
# Usage: scripts/qa-runtime.sh <subcommand>
#   guard           resolve QA compose config and run the production-intersection guard
#   guard-selftest  prove the guard refuses production names BEFORE any docker mutation
#   up              guarded: fresh QA stack up + wait for web+RFB readiness
#   baseline        guarded: reproduce the baseline defect (x11vnc TERM => HTTP 200 but RFB dead)
#   cleanup         guarded: compose down -v (QA volume only) + verification receipt
#   manifest        write manifest.json (source revision, diff hash, file hashes, versions)
#   build           guarded: candidate image kakaotalk-wine:reliability-qa (FROM baseline + COPY scripts)
#                   plus a negative control proving a build can never overwrite the baseline tag
#   healthy         guarded: candidate up; probe ready, HTTP 200, WS RFB handshake, Docker health healthy
#   recovery [case...]  guarded, fresh QA volume per case: app|xvfb|x11vnc|websockify|freeze|stop (default: all)
#   nonfaults [a|b|c...] guarded, fresh volume per scenario: a launcher/runner exit with app alive, b window minimized/unmapped,
#                   c login-wait idle; asserts 0 relaunches, unchanged PIDs/recovery_count/budget/RestartCount (task-2-nonfaults.json)
#   circuit [unit|real] unit: fake-clock budget function run (sourced from entrypoint.sh); real: consecutive kills until
#                   phase=blocked, observation window, bounded RestartCount (task-2-circuit.json)
#   init-failure    guarded: wineboot failure injected (QA_WINEBOOT_TIMEOUT) => no .initialized, exit 10, budget used, blocked (task-2-init-failure.json)
#   mutation        guarded: temp-copy mutant (vnc/web relaunch no-op) built as kakaotalk-wine:reliability-mutant; x11vnc recovery
#                   case must FAIL on it and pass on the candidate; mutant tag + temp dir removed (task-2-mutation.json)
#   probe-selftest  guarded: healthy candidate + fake RFB listeners on a spare loopback port inside the QA container (KAKAO_VNC_PORT):
#                   "RFB 003." then EOF/hold => probe non-ready layer=vnc, full 12-byte banner => ready (task-2-probe.json)
#   boot-deadline   guarded: QA-only hanging wineboot shim (docker cp into the created container) + KAKAO_WINEBOOT_TIMEOUT=600 =>
#                   boot exits (code 13) at the shared 90s deadline + cleanup, no .initialized, budget consumed (task-2-boot-deadline.json)
#   operations      guarded: kakaoctl status/diagnose/restart on the QA stack (wrong-target refusal, random sentinel as QA VNC_PASSWORD absent
#                   from output, budget reset by restart, exit-code propagation) (task-3-operations.json); then `cleanup task-3`
#   cleanup [task-2|task-2-d]  receipt name prefix (default task-1); task-2-d writes task-2-cleanup-d.json
#   subset runs (case/part arguments) write task-2-*-repeat.json and never overwrite the full-run receipt
#
# GUARD: every mutating docker call (up, down, exec kill) goes through qa_mutate(),
# which aborts unless resolve_guard() already parsed the resolved QA config and found
# no production intersection. A refusal exits 3 with no side effects.
#
# EXIT CODE CONVENTION (a reproduction is NOT a health verdict):
#   baseline:
#     0  defect REPRODUCED  (harness PASS; system_healthy is false by definition)
#     1  defect NOT reproduced (observed recovery or RFB kept working; investigate)
#     2  precondition/environment failure (never became healthy, tools missing, ports busy, ...)
#     3  guard refusal (no side effects)
#   other subcommands: 0 ok, 2 failure/verification mismatch, 3 guard refusal.
#   64 usage error.
# The baseline JSON carries the same facts separately:
#   result.defect_reproduced (bool), result.system_healthy (bool), result.harness_status.
#
# Tunables (env): QA_IMAGE, QA_READY_TIMEOUT (300s), QA_OBSERVE_SECS (120s),
#   QA_POLL_INTERVAL (3s), QA_EVIDENCE_DIR, QA_RECOVERY_DEADLINE (240s), QA_WINDOW_DEADLINE (90s),
#   QA_HEALTHY_OBSERVE (45s). All waits are deadline-bounded predicate polls.

set -uo pipefail
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPOSE_PATH_SEPARATOR

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
REPO_ROOT=$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)
COMPOSE_FILE="$REPO_ROOT/docker-compose.qa.yml"

QA_PROJECT=kakao-reliability-qa
QA_SERVICE=kakaotalk
QA_CONTAINER=kakaotalk-reliability-qa
QA_VOLUME=kakao-reliability-qa_kakao-qa-data
QA_NETWORK=kakao-reliability-qa_default
QA_HTTP_PORT=24500
QA_RDP_PORT=23389
BASELINE_TAG=kakaotalk-wine:reliability-baseline
export QA_IMAGE="${QA_IMAGE:-$BASELINE_TAG}"

PROD_CONTAINER=kakaotalk-wine
PROD_SRC="${PROD_SRC:-/home/root1/kakaotalk-web}"
PROD_IMAGE_TAG=kakaotalk-wine:local
PROD_IMAGE_ID_EXPECT=sha256:dcdc7a66f7ab925ca0d62c166b7407b9b1f635071d28aa92d59eb583e6bfc9a3
ENTRYPOINT_SHA_EXPECT=0ab63fb807bb3bb11112b8c61400926f1d88e75160f807bda23adaea2ba9c7e6
RUNNER_SHA_EXPECT=3d907e76747210b99dfba610892827f9969fc89d6965a71925f21ce291543b5b

VNC_URL="http://localhost:${QA_HTTP_PORT}/vnc.html?autoconnect=true&resize=scale"
WS_URL="ws://127.0.0.1:${QA_HTTP_PORT}/websockify"
HTTP_URL="http://127.0.0.1:${QA_HTTP_PORT}/"

READY_TIMEOUT="${QA_READY_TIMEOUT:-300}"
OBSERVE_SECS="${QA_OBSERVE_SECS:-120}"
POLL_INTERVAL="${QA_POLL_INTERVAL:-3}"

EX_REPRODUCED=0
EX_NOT_REPRODUCED=1
EX_ENV=2
EX_GUARD=3
EX_USAGE=64

GUARD_PASSED=0
RESOLVED_CONFIG=""
MUTANT_DIR=""
MUTANT_BUILT=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; mutant_teardown 2>/dev/null' EXIT

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[qa-runtime %s] %s\n' "$(now_utc)" "$*" >&2; }
die_env() { log "ERROR: $*"; exit "$EX_ENV"; }

############################ tooling / evidence helpers ############################

need_tools() {
  local t
  for t in docker jq curl python3 timeout ss git sha256sum; do
    command -v "$t" >/dev/null 2>&1 || die_env "missing tool: $t"
  done
  python3 -c 'import websocket' 2>/dev/null || die_env "python3 module 'websocket' (websocket-client) is required for the RFB probe"
}

evidence_dir() {
  if [ -n "${QA_EVIDENCE_DIR:-}" ]; then
    printf '%s' "$QA_EVIDENCE_DIR"
  else
    printf '%s/doc/evidence/kakaotalk-runtime-reliability/%s' "$REPO_ROOT" "$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  fi
}

write_evidence() { # <file-name> <json>
  local dir; dir=$(evidence_dir)
  mkdir -p "$dir" || die_env "cannot create $dir"
  printf '%s\n' "$2" | jq . >"$dir/$1.tmp" || die_env "invalid JSON for $1"
  chmod 644 "$dir/$1.tmp" && mv "$dir/$1.tmp" "$dir/$1"
  log "evidence written: ${dir#"$REPO_ROOT"/}/$1"
}

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

compose() { docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" "$@"; }

############################ production-intersection guard ############################

config_json() {
  if [ "${QA_SELFTEST:-}" = 1 ] && [ -n "${QA_SELFTEST_CONFIG:-}" ]; then
    cat "$QA_SELFTEST_CONFIG"
  else
    docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" ${QA_COMPOSE_OVERRIDE:+-f "$QA_COMPOSE_OVERRIDE"} config --format json
  fi
}

# stdin: resolved compose config JSON. stdout: one violation per line (empty = clean).
guard_violations() {
  jq -r \
    --arg proj "$QA_PROJECT" --arg svc "$QA_SERVICE" --arg cname "$QA_CONTAINER" \
    --arg vprefix "${QA_PROJECT}_" \
    '
    def prod_containers: ["kakaotalk-web","kakaotalk-wine"];
    def prod_volumes: ["kakaotalk-web_kakao-wine-data"];
    def prod_ports: ["14500","13389"];
    def prod_images: ["kakaotalk-wine:local"];
    def prod_projects: ["kakaotalk-web"];
    def prod_networks: ["kakaotalk-web_default"];
    def isin($list; $x): $list | any(. == $x);
    [
      (if isin(prod_projects; (.name // "")) then "project name \(.name) intersects production" else empty end),
      (if (.name // "") != $proj then "project name \(.name) is not the QA project \($proj)" else empty end),
      (.networks // {} | to_entries[] | (.value.name // .key) as $n
         | if isin(prod_networks; $n) then "network \($n) intersects production" else empty end),
      (.volumes // {} | to_entries[] | (.value.name // .key) as $n
         | (if isin(prod_volumes; $n) then "volume \($n) intersects production" else empty end),
           (if ($n | startswith($vprefix) | not) then "volume \($n) is not QA-owned (prefix \($vprefix))" else empty end),
           (if (.value.external // false) == true then "volume \($n) is external" else empty end)),
      ((.services // {} | keys) as $k
         | if $k != [$svc] then "services must be exactly [\($svc)], got \($k)" else empty end),
      (.services // {} | to_entries[] | .value as $s
         | (
           (if isin(prod_containers; ($s.container_name // "")) then "container_name \($s.container_name) intersects production" else empty end),
           (if ($s.container_name // "") != $cname then "container_name \($s.container_name) is not the QA container \($cname)" else empty end),
           (if isin(prod_images; ($s.image // "")) then "image \($s.image) intersects production tag" else empty end),
           (if (($s.image // "") | test("^kakaotalk-wine:reliability-(baseline|qa|mutant)$") | not) then "image \($s.image) is not a QA image tag" else empty end),
           (($s.ports // [])[] | (.published | tostring) as $p
              | (if isin(prod_ports; $p) then "published port \($p) intersects production" else empty end),
                (if ($p != "24500" and $p != "23389") then "published port \($p) is not a QA port" else empty end),
                (if (.host_ip // "") != "127.0.0.1" then "port \($p) is not bound to 127.0.0.1" else empty end)),
           (($s.volumes // [])[]
              | (if .type != "volume" then "non-volume mount (\(.type)) -> \(.target) is not allowed in QA" else empty end),
                (if isin(prod_volumes; (.source // "")) then "mount source \(.source) intersects production volume" else empty end)),
           (if ($s.network_mode // "") == "host" or ($s.privileged // false) == true or ($s.pid // "") == "host" then "host network/pid/privileged is not allowed" else empty end)
         ))
    ] | .[]
    ' 2>&1
}

# Parse resolved config + refuse (exit 3) on any production intersection.
resolve_guard() {
  local cfg viol rc
  cfg=$(config_json) || { log "REFUSED: cannot resolve QA compose config"; exit "$EX_GUARD"; }
  [ -n "$cfg" ] || { log "REFUSED: empty QA compose config"; exit "$EX_GUARD"; }
  viol=$(printf '%s' "$cfg" | guard_violations); rc=$?
  if [ "$rc" -ne 0 ]; then
    log "REFUSED: guard could not evaluate config: $viol"
    exit "$EX_GUARD"
  fi
  if [ -n "$viol" ]; then
    log "REFUSED: QA config intersects production / is not QA-owned (no docker mutation performed):"
    printf '%s\n' "$viol" | while IFS= read -r l; do log "  - $l"; done
    exit "$EX_GUARD"
  fi
  # service volume sources must resolve to a top-level volume with the QA prefix
  if ! printf '%s' "$cfg" | jq -e --arg vp "${QA_PROJECT}_" '
        . as $c | [ (.services[]?.volumes // [])[] | select(.type=="volume") | .source ]
        | all(. as $s | ($c.volumes[$s].name // "") | startswith($vp))' >/dev/null 2>&1; then
    log "REFUSED: a service volume source does not resolve to a QA-owned volume"
    exit "$EX_GUARD"
  fi
  RESOLVED_CONFIG="$cfg"
  GUARD_PASSED=1
}

qa_mutate() { # every state-changing docker call must pass through here
  if [ "$GUARD_PASSED" != 1 ]; then
    log "BUG: mutation attempted before guard passed; aborting"
    exit "$EX_GUARD"
  fi
  "$@"
}

############################ read-only snapshots ############################

prod_snapshot() { # production container facts (docker inspect only)
  local out
  if out=$(docker inspect --type container "$PROD_CONTAINER" 2>/dev/null); then
    printf '%s' "$out" | jq -c '.[0] | {
      found: true, id: .Id, image_id: .Image, status: .State.Status, running: .State.Running,
      started_at: .State.StartedAt, restart_count: .RestartCount,
      healthcheck: .Config.Healthcheck, health_state: (.State.Health // null),
      restart_policy: .HostConfig.RestartPolicy,
      compose: { project: .Config.Labels["com.docker.compose.project"],
                 service: .Config.Labels["com.docker.compose.service"],
                 working_dir: .Config.Labels["com.docker.compose.project.working_dir"],
                 config_files: .Config.Labels["com.docker.compose.project.config_files"],
                 config_hash: .Config.Labels["com.docker.compose.config-hash"],
                 compose_version: .Config.Labels["com.docker.compose.version"] },
      volumes: [.Mounts[] | select(.Type=="volume") | {name: .Name, destination: .Destination}],
      bind_mount_destinations: [.Mounts[] | select(.Type=="bind") | .Destination],
      port_bindings: .HostConfig.PortBindings }'
  else
    printf '{"found":false}'
  fi
}

prod_image_facts() {
  jq -n -c --arg tag "$PROD_IMAGE_TAG" --arg id "$(docker image inspect "$PROD_IMAGE_TAG" --format '{{.Id}}' 2>/dev/null)" \
    --arg expect "$PROD_IMAGE_ID_EXPECT" '{tag:$tag, id:$id, matches_plan_image_id: ($id == $expect)}'
}

prod_runtime_hashes() { # read-only sha256sum inside the production container
  timeout 20 docker exec "$PROD_CONTAINER" sha256sum /usr/local/bin/kakao-entrypoint /usr/local/bin/run-kakao 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length>0) | split("  ") | {(.[1]): .[0]}) | add // {}'
}

worktree_state() {
  local st diff
  st=$(git -C "$REPO_ROOT" status --porcelain=v1 -- . ':(exclude)doc/evidence' 2>/dev/null)
  diff=$(git -C "$REPO_ROOT" diff --binary 2>/dev/null | sha256sum | cut -d' ' -f1)
  jq -n -c --arg st "$st" --arg diff "$diff" --arg head "$(git -C "$REPO_ROOT" rev-parse HEAD)" \
    '{head:$head, status_excluding_evidence: ($st | split("\n") | map(select(length>0))),
      status_sha256: ($st | @base64), diff_binary_sha256:$diff}'
}

source_info() {
  jq -n -c \
    --arg head "$(git -C "$REPO_ROOT" rev-parse HEAD)" --arg short "$(git -C "$REPO_ROOT" rev-parse --short HEAD)" \
    --arg branch "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)" \
    --arg diff "$(git -C "$REPO_ROOT" diff --binary | sha256sum | cut -d' ' -f1)" \
    --arg ent_expect "$ENTRYPOINT_SHA_EXPECT" --arg run_expect "$RUNNER_SHA_EXPECT" \
    --arg ent_wt "$(sha_of "$REPO_ROOT/docker/entrypoint.sh")" --arg run_wt "$(sha_of "$REPO_ROOT/docker/run-kakao.sh")" \
    --arg ent_src "$(sha_of "$PROD_SRC/docker/entrypoint.sh")" --arg run_src "$(sha_of "$PROD_SRC/docker/run-kakao.sh")" \
    --argjson prod "$(prod_runtime_hashes)" \
    '{revision:$head, short:$short, branch:$branch, git_diff_binary_sha256:$diff,
      plan_expected:{entrypoint:$ent_expect, runner:$run_expect},
      worktree:{entrypoint:$ent_wt, runner:$run_wt},
      production_source_repo:{entrypoint:$ent_src, runner:$run_src},
      production_container:{entrypoint:($prod["/usr/local/bin/kakao-entrypoint"]), runner:($prod["/usr/local/bin/run-kakao"])},
      all_match_plan: (([$ent_wt,$ent_src,($prod["/usr/local/bin/kakao-entrypoint"])] | all(. == $ent_expect))
                       and ([$run_wt,$run_src,($prod["/usr/local/bin/run-kakao"])] | all(. == $run_expect)))}'
}

############################ probes ############################

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true; }

# Real RFB handshake through the web path: WebSocket to websockify, expect "RFB 003." banner.
rfb_probe() {
  timeout 25 python3 - "$WS_URL" 5 <<'PY'
import json, sys, time
import websocket
url, timeout = sys.argv[1], float(sys.argv[2])
t0 = time.time()
res = {"ok": False, "banner": None, "error": None}
ws = None
try:
    ws = websocket.create_connection(url, timeout=timeout, subprotocols=["binary"])
    data = ws.recv()
    if isinstance(data, str):
        data = data.encode("latin-1", "replace")
    banner = bytes(data[:12])
    res["banner"] = banner.decode("ascii", "replace").rstrip()
    res["ok"] = banner.startswith(b"RFB 003.")
    if not res["ok"]:
        res["error"] = "unexpected first frame"
except Exception as e:  # any failure to obtain a banner is an RFB failure
    res["error"] = "%s: %s" % (type(e).__name__, str(e)[:200])
finally:
    if ws is not None:
        try:
            ws.close()
        except Exception:
            pass
res["elapsed_ms"] = int((time.time() - t0) * 1000)
print(json.dumps(res))
PY
}

rfb_json() { local o; o=$(rfb_probe) || true; [ -n "$o" ] && printf '%s' "$o" || printf '{"ok":false,"banner":null,"error":"probe produced no output"}'; }

container_inspect_line() { # status restart_count started_at running
  docker inspect "$1" --format '{{.State.Status}} {{.RestartCount}} {{.State.StartedAt}} {{.State.Running}}' 2>/dev/null
}

proc_survey() { # JSON array of {pid,comm,state} inside container $1 (QA only)
  timeout 25 docker exec -i "$1" sh -s 2>/dev/null <<'EOS' | jq -R -s -c 'split("\n") | map(select(length>0) | split(" ") | {pid:(.[0]|tonumber), comm:.[1], state:(.[2] // "")})'
for p in /proc/[0-9]*; do
  c=$(cat "$p/comm" 2>/dev/null) || continue
  s=$(sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "$p/status" 2>/dev/null)
  echo "${p#/proc/} $(echo "$c" | tr ' ' '_') $s"
done
EOS
}

live_pids() { # <survey-json> <comm>
  printf '%s' "$1" | jq -c --arg c "$2" '[.[] | select(.comm==$c and .state!="Z" and .state!="X") | .pid]'
}

vnc_html_capture() { # curl -i of the noVNC page (first lines + body hash)
  local f="$WORK/vnc.html.$$" code
  code=$(curl -sS -i --max-time 8 -o "$f" -w '%{http_code}' "$VNC_URL" 2>/dev/null || true)
  jq -n -c --arg url "$VNC_URL" --arg code "${code:-000}" \
    --arg head "$(head -n 12 "$f" 2>/dev/null | tr -d '\r')" \
    --arg bytes "$(wc -c <"$f" 2>/dev/null || echo 0)" --arg sha "$(sha_of "$f")" \
    --argjson novnc "$(grep -qi 'novnc' "$f" 2>/dev/null && echo true || echo false)" \
    '{curl_i_url:$url, http_status:($code|tonumber? // 0), headers_excerpt:($head|split("\n")), response_bytes:($bytes|tonumber), response_sha256:$sha, mentions_novnc:$novnc}'
  rm -f "$f"
}

############################ fresh up / readiness ############################

port_busy() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

qa_label_project() { # <kind> <name> -> compose project label or empty
  case "$1" in
    container) docker inspect --type container "$2" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null ;;
    volume) docker volume inspect "$2" --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null ;;
  esac
}

STALE_CLEANED=false
prep_fresh() {
  local c_exists=false v_exists=false lab
  if docker inspect --type container "$QA_CONTAINER" >/dev/null 2>&1; then
    c_exists=true
    lab=$(qa_label_project container "$QA_CONTAINER")
    [ "$lab" = "$QA_PROJECT" ] || { log "REFUSED: container $QA_CONTAINER exists but belongs to project '${lab:-none}'"; exit "$EX_GUARD"; }
  fi
  if docker volume inspect "$QA_VOLUME" >/dev/null 2>&1; then
    v_exists=true
    lab=$(qa_label_project volume "$QA_VOLUME")
    [ "$lab" = "$QA_PROJECT" ] || { log "REFUSED: volume $QA_VOLUME exists but belongs to project '${lab:-none}'"; exit "$EX_GUARD"; }
  fi
  if $c_exists || $v_exists; then
    log "stale QA state found (container=$c_exists volume=$v_exists); removing QA-owned leftovers for a fresh volume"
    qa_mutate timeout 120 docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans --timeout 30 >&2 \
      || die_env "stale QA cleanup failed"
    STALE_CLEANED=true
  fi
  docker volume inspect "$QA_VOLUME" >/dev/null 2>&1 && die_env "QA volume still present after cleanup"
  docker image inspect "$QA_IMAGE" >/dev/null 2>&1 \
    || die_env "image $QA_IMAGE not found (baseline: docker tag $PROD_IMAGE_ID_EXPECT $BASELINE_TAG)"
  port_busy "$QA_HTTP_PORT" && die_env "port $QA_HTTP_PORT already in use"
  port_busy "$QA_RDP_PORT" && die_env "port $QA_RDP_PORT already in use"
  return 0
}

# QA_SCRIPTS_MODE=image            run the image's embedded scripts (default; candidate image in todo 2)
# QA_SCRIPTS_MODE=production-runtime  baseline: production's *running* scripts differ from the image
#   (docker diff kakaotalk-wine shows both /usr/local/bin scripts changed in the container layer), so the
#   plan-pinned worktree copies (hash-verified) are docker-cp'd into the created-but-not-started QA container.
RUNTIME_SRC_DIR="" # empty = worktree docker/; ui-survey baseline points it at the git HEAD (91cff7e) copies
cp_runtime_scripts() { # <container-id>; worktree files may lack the exec bit, so stream them as 0755 via tar
  tar -C "${RUNTIME_SRC_DIR:-$REPO_ROOT/docker}" --mode=0755 --owner=0 --group=0 \
    --transform 's,^entrypoint.sh$,kakao-entrypoint,;s,^run-kakao.sh$,run-kakao,' \
    -cf - entrypoint.sh run-kakao.sh | timeout 30 docker cp - "$1:/usr/local/bin"
}
SCRIPTS_APPLIED=null
# QA_APP_SEED_DIR=<dir>  OPT-IN QA fixture. The image bundles KakaoTalk 26.1.2.4; on a FRESH volume that stale build shows an error dialog
# ("KakaoTalk files are corrupted, reinstall") instead of the login window, while production runs the self-updated 26.8.x from its
# long-lived volume. The seed (a copy of production's app binaries, no user data) is docker-cp'd into the created, not yet started QA
# container at the install path so sync_kakao_files sees an up-to-date installation. Never used by default: without it, fresh-volume
# scenarios fail honestly on the login-window assertion.
cp_app_seed() { # <container-id> <seed-dir>
  local -a names; mapfile -t names < <(ls -A "$2")
  [ "${#names[@]}" -gt 0 ] && [ -f "$2/KakaoTalk.exe" ] || return 1
  tar -C "$2" --owner=0 --group=0 --transform 's,^,data/wineprefix/drive_c/Program Files/Kakao/KakaoTalk/,' -cf - "${names[@]}" \
    | timeout 120 docker cp - "$1:/"
}
qa_up() {
  local seed=${QA_APP_SEED_DIR:-}
  if [ "${QA_SCRIPTS_MODE:-image}" != production-runtime ] && [ -z "$seed" ]; then
    qa_mutate timeout 180 docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" ${QA_COMPOSE_OVERRIDE:+-f "$QA_COMPOSE_OVERRIDE"} up -d --no-build --pull never >&2
    return
  fi
  local e r
  if [ "${QA_SCRIPTS_MODE:-image}" = production-runtime ]; then
    e=$(sha_of "${RUNTIME_SRC_DIR:-$REPO_ROOT/docker}/entrypoint.sh"); r=$(sha_of "${RUNTIME_SRC_DIR:-$REPO_ROOT/docker}/run-kakao.sh")
    if [ "$e" != "$ENTRYPOINT_SHA_EXPECT" ] || [ "$r" != "$RUNNER_SHA_EXPECT" ]; then
      log "worktree runtime scripts differ from the plan-pinned production hashes; refusing production-runtime mode"
      return 1
    fi
  fi
  qa_mutate timeout 120 docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" ${QA_COMPOSE_OVERRIDE:+-f "$QA_COMPOSE_OVERRIDE"} create --no-build --pull never >&2 || return 1
  local cid; cid=$(docker inspect --type container "$QA_CONTAINER" --format '{{.Id}}' 2>/dev/null) || return 1
  [ "$(qa_label_project container "$QA_CONTAINER")" = "$QA_PROJECT" ] || return 1
  if [ "${QA_SCRIPTS_MODE:-image}" = production-runtime ]; then
    qa_mutate cp_runtime_scripts "$cid" || return 1
    SCRIPTS_APPLIED=$(jq -n -c --arg e "$e" --arg r "$r" '{mode:"production-runtime", entrypoint_sha256:$e, runner_sha256:$r, method:"tar stream (mode 0755) via docker cp into the created, not yet started QA container"}')
  fi
  if [ -n "$seed" ]; then
    log "QA app seed: copying KakaoTalk binaries from $seed into the created QA container (opt-in fixture)"
    qa_mutate cp_app_seed "$cid" "$seed" || { log "app seed copy failed"; return 1; }
  fi
  qa_mutate timeout 60 docker start "$cid" >&2
}

READY_REASON=""
READY_SECS=0
wait_ready() { # bounded poll: HTTP 200 AND real RFB banner through the web path
  local start=$SECONDS deadline=$((SECONDS + READY_TIMEOUT)) http rfb st
  while :; do
    st=$(docker inspect "$QA_CONTAINER" --format '{{.State.Status}}' 2>/dev/null || true)
    case "$st" in exited|dead|removing|restarting|"") READY_REASON="container state '${st:-missing}' while waiting (fresh boot must not restart)"; return 1;; esac
    http=$(http_code "$HTTP_URL")
    if [ "$http" = 200 ]; then
      rfb=$(rfb_json)
      if printf '%s' "$rfb" | jq -e '.ok' >/dev/null 2>&1; then READY_SECS=$((SECONDS - start)); return 0; fi
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      READY_REASON="not ready within ${READY_TIMEOUT}s (last http=${http:-none})"; return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

# Facts of the image's own embedded scripts (throwaway container, no ports/volumes), compared with the runtime scripts.
image_embedded_facts() {
  local d1 d2
  d1=$(qa_mutate timeout 60 docker run --rm --entrypoint sh "$QA_IMAGE" -c 'sha256sum /usr/local/bin/kakao-entrypoint /usr/local/bin/run-kakao' 2>/dev/null \
        | jq -R -s -c 'split("\n") | map(select(length>0) | split("  ") | {(.[1]): .[0]}) | add // {}')
  [ -n "$d1" ] || d1='{}'
  d2=$(qa_mutate timeout 60 docker run --rm --entrypoint cat "$QA_IMAGE" /usr/local/bin/kakao-entrypoint 2>/dev/null \
        | diff - "$REPO_ROOT/docker/entrypoint.sh" | grep -c '^[<>]')
  jq -n -c --argjson h "$d1" --arg d "${d2:-0}" --arg e "$ENTRYPOINT_SHA_EXPECT" --arg r "$RUNNER_SHA_EXPECT" \
    '{image_embedded: {entrypoint:$h["/usr/local/bin/kakao-entrypoint"], runner:$h["/usr/local/bin/run-kakao"]},
      entrypoint_matches_plan_production_runtime: ($h["/usr/local/bin/kakao-entrypoint"] == $e),
      runner_matches_plan_production_runtime: ($h["/usr/local/bin/run-kakao"] == $r),
      entrypoint_diff_lines_vs_production_runtime: ($d|tonumber),
      finding: "production runtime scripts live in the container layer (docker cp), not in the image; the image alone does not reproduce production runtime"}'
}

facts_script() { # raw key=value facts printed INSIDE an image/container (wine + KakaoTalk versions, N2)
  cat <<'EOS'
echo "wine_version=$(wine --version 2>&1 | head -n 1)"
echo "kakaotalk_exe_sha256=$(sha256sum /opt/kakao/KakaoTalk/KakaoTalk.exe 2>/dev/null | cut -d' ' -f1)"
echo "kakaotalk_exe_size=$(stat -c %s /opt/kakao/KakaoTalk/KakaoTalk.exe 2>/dev/null)"
echo "kakaotalk_changelog_top_version=$(sed -n 's/^### //p' /opt/kakao/KakaoTalk/ChangeLogs_en.md 2>/dev/null | head -n 1)"
echo "entrypoint_sha256=$(sha256sum /usr/local/bin/kakao-entrypoint 2>/dev/null | cut -d' ' -f1)"
echo "runner_sha256=$(sha256sum /usr/local/bin/run-kakao 2>/dev/null | cut -d' ' -f1)"
dpkg-query -W -f='pkg:${Package}=${Version}\n' 'wine*' 'winehq*' xvfb x11vnc novnc websockify openbox 2>/dev/null
EOS
}

parse_facts() { # stdin: raw facts text
  jq -R -s -c '
    split("\n") | map(select(length>0)) as $l
    | { wine: { version: (($l[] | select(startswith("wine_version=")) | sub("^wine_version=";"")) // null) },
        kakaotalk: { exe_path: "/opt/kakao/KakaoTalk/KakaoTalk.exe",
                     exe_sha256: (($l[] | select(startswith("kakaotalk_exe_sha256=")) | sub("^[^=]*=";"")) // null),
                     exe_size: (($l[] | select(startswith("kakaotalk_exe_size=")) | sub("^[^=]*=";"")) // null),
                     version_from_changelog: ((($l[] | select(startswith("kakaotalk_changelog_top_version=")) | sub("^[^=]*=";"") | rtrimstr("\r"))) // null) },
        scripts_in_container: { entrypoint: (($l[] | select(startswith("entrypoint_sha256=")) | sub("^[^=]*=";"")) // null),
                                runner: (($l[] | select(startswith("runner_sha256=")) | sub("^[^=]*=";"")) // null) },
        packages: [ $l[] | select(startswith("pkg:")) | sub("^pkg:";"") | select(endswith("=") | not) ] }'
}

collect_image_facts() { # <running QA container id>; baseline facts, recorded separately for wine and KakaoTalk (N2)
  facts_script | timeout 40 docker exec -i "$1" sh -s 2>/dev/null | parse_facts
}

image_facts_for() { # <image tag>: same facts from a throwaway network-less container (no ports/volumes)
  facts_script | qa_mutate timeout 60 docker run --rm -i --network none --entrypoint sh "$1" -s 2>/dev/null | parse_facts
}

############################ baseline ############################

# globals assembled into the evidence JSON
J_IMAGE=null; J_FACTS=null; J_PRE=null; J_FAULT=null; J_OBS=null; J_SRC=null
J_PROD_BEFORE=null; J_PROD_AFTER=null; J_WT_BEFORE=null; J_WT_AFTER=null
J_BROWSER_HEALTHY=null; J_BROWSER_POST=null; J_PROC_BEFORE=null; J_PROC_AFTER=null
B_STARTED=""; B_STATUS="precondition_failed"; B_REASON=""

finish_baseline() { # <exit-code>
  local code=$1 reproduced=false finished
  [ "$code" = "$EX_REPRODUCED" ] && reproduced=true
  finished=$(now_utc)
  J_PROD_AFTER=$(prod_snapshot); J_WT_AFTER=$(worktree_state)
  local json
  json=$(jq -n -c \
    --arg started "$B_STARTED" --arg finished "$finished" --arg status "$B_STATUS" --arg reason "$B_REASON" \
    --argjson code "$code" --argjson reproduced "$reproduced" \
    --argjson src "$J_SRC" --argjson image "$J_IMAGE" --argjson facts "$J_FACTS" \
    --argjson pre "$J_PRE" --argjson fault "$J_FAULT" --argjson obs "$J_OBS" \
    --argjson pb "$J_PROD_BEFORE" --argjson pa "$J_PROD_AFTER" --argjson wb "$J_WT_BEFORE" --argjson wa "$J_WT_AFTER" \
    --argjson procb "$J_PROC_BEFORE" --argjson proca "$J_PROC_AFTER" \
    --arg observe "$OBSERVE_SECS" --arg ready "$READY_TIMEOUT" \
    '{
      task: "task-1-baseline", schema: 1, command: "bash scripts/qa-runtime.sh baseline",
      started_at: $started, finished_at: $finished, exit_code: $code,
      result: { defect_reproduced: $reproduced, system_healthy: false, harness_status: $status, reason: $reason,
                note: "defect_reproduced=true means the BASELINE BUG was observed (harness PASS); system_healthy is always false after the fault." },
      exit_code_convention: { "0":"defect reproduced (harness PASS)", "1":"defect NOT reproduced", "2":"precondition/environment failure", "3":"guard refusal (no side effects)", "64":"usage" },
      source: $src, image: $image, image_facts_baseline: $facts,
      pre_fault: $pre, fault: $fault, observation: $obs,
      processes_before_fault: $procb, processes_after_observation: $proca,
      production: { before: $pb, after: $pa,
                    unchanged: (($pb.found // false) and ($pa.found // false)
                                and $pb.id == $pa.id and $pb.started_at == $pa.started_at
                                and $pb.restart_count == $pa.restart_count and $pb.status == $pa.status) },
      worktree: { before: $wb, after: $wa,
                  unchanged_excluding_evidence: ($wb.status_sha256 == $wa.status_sha256 and $wb.diff_binary_sha256 == $wa.diff_binary_sha256) },
      bounds: { ready_timeout_s: ($ready|tonumber), observe_window_s: ($observe|tonumber), fixed_sleep_synchronization: false,
                note: "all waits are deadline-bounded predicate polls; the observation window is the one place where elapsed time itself is the behavior under test" },
      adversarial: {
        misleading_success_output: { probed: true, finding: "HTTP 200 on the websockify/noVNC static path stays true while the RFB handshake through the same path fails; readiness and verdicts require the RFB banner, never HTTP alone." },
        dirty_worktree: { probed: true, finding: "worktree status (excluding doc/evidence) and tracked diff hash recorded before and after; see worktree.unchanged_excluding_evidence" },
        hung_commands: { probed: true, finding: "every curl/docker/python call is wrapped in timeout/max-time; wait loops have deadlines" },
        stale_state: { probed: true, finding: "any QA-owned leftover container/volume is removed first; run starts on a freshly created QA volume" },
        flaky_tests: { probed: true, finding: "no fixed sleeps for synchronization; state predicates with deadlines, repeated samples over the observation window" },
        production_interference: { probed: true, finding: "production only inspected; before/after snapshot compared (production.unchanged)" },
        secrets_leak: { probed: true, finding: "N/A: QA uses empty VNC_PASSWORD, no account data, no share bind mount" },
        data_loss: { probed: true, finding: "N/A: only the QA-only volume is created/removed; production volume never referenced" },
        network_exposure: { probed: true, finding: "QA ports bound to 127.0.0.1 only (guard-enforced)" }
      }
    }') || die_env "failed to assemble baseline JSON"
  write_evidence task-1-baseline.json "$json"
  local bjson
  bjson=$(jq -n -c --arg url "$VNC_URL" --arg ws "$WS_URL" \
    --argjson h "$J_BROWSER_HEALTHY" --argjson p "$J_BROWSER_POST" \
    '{task:"task-1-browser", schema:1, url:$url, browser_page_checked:false, browser_tool_available:false,
      note:"No browser tool was available to the worker. Recorded instead: curl -i of vnc.html and a real WebSocket RFB handshake through the same websockify path (\($ws)). The orchestrator must perform the real noVNC page check; browser_page_checked is false on purpose.",
      substitute_evidence: {healthy_phase:$h, post_fault_phase:$p},
      interpretation: "healthy phase: page served and RFB banner received; post-fault phase: page still served (HTTP 200) but no RFB banner, i.e. the noVNC page would sit on a dead connection."}') \
    && write_evidence task-1-browser.json "$bjson"
  printf '%s\n' "$json" | jq .
  exit "$code"
}

cmd_baseline() {
  need_tools
  resolve_guard
  B_STARTED=$(now_utc)
  QA_SCRIPTS_MODE=production-runtime
  J_PROD_BEFORE=$(prod_snapshot); J_WT_BEFORE=$(worktree_state)
  J_SRC=$(source_info)
  prep_fresh
  J_IMAGE=$(jq -n -c --arg tag "$QA_IMAGE" --arg id "$(docker image inspect "$QA_IMAGE" --format '{{.Id}}')" \
    --arg created "$(docker image inspect "$QA_IMAGE" --format '{{.Created}}')" \
    --argjson prod "$(prod_image_facts)" \
    '{qa_image_tag:$tag, qa_image_id:$id, created:$created, production_image:$prod, same_as_production_image: ($id == $prod.id)}')
  log "bringing up QA stack ($QA_IMAGE)"
  if ! qa_up; then B_REASON="compose create/up failed or plan-pinned scripts mismatch"; finish_baseline "$EX_ENV"; fi
  J_IMAGE=$(printf '%s' "$J_IMAGE" | jq -c --argjson e "$(image_embedded_facts)" --argjson s "$SCRIPTS_APPLIED" \
    '. + {scripts: {image_embedded_facts:$e, applied_to_qa_container:$s}}')
  local cid; cid=$(docker inspect "$QA_CONTAINER" --format '{{.Id}}' 2>/dev/null)
  [ -n "$cid" ] || { B_REASON="QA container missing after up"; finish_baseline "$EX_ENV"; }
  [ "$(qa_label_project container "$QA_CONTAINER")" = "$QA_PROJECT" ] || { B_REASON="QA container lacks QA project label"; finish_baseline "$EX_GUARD"; }

  log "waiting (bounded ${READY_TIMEOUT}s) for HTTP 200 + RFB banner through the web path"
  if ! wait_ready; then
    B_REASON="precondition: $READY_REASON"
    J_PRE=$(jq -n -c --arg r "$READY_REASON" --arg logs "$(timeout 20 docker logs --tail 30 "$QA_CONTAINER" 2>&1 | tail -n 30)" '{ready:false, reason:$r, container_log_tail:($logs|split("\n"))}')
    J_BROWSER_HEALTHY=$(jq -n -c '{captured:false}'); J_BROWSER_POST=$(jq -n -c '{captured:false}')
    finish_baseline "$EX_ENV"
  fi
  J_FACTS=$(collect_image_facts "$cid") || J_FACTS=null
  [ -n "$J_FACTS" ] || J_FACTS=null
  J_SRC=$(printf '%s' "$J_SRC" | jq -c --argjson f "${J_FACTS:-null}" '. + {qa_container_scripts: ($f.scripts_in_container // null)}')

  J_PROC_BEFORE=$(proc_survey "$cid")
  local vnc_before; vnc_before=$(live_pids "$J_PROC_BEFORE" x11vnc)
  local web_before; web_before=$(live_pids "$J_PROC_BEFORE" websockify)
  if [ "$(printf '%s' "$vnc_before" | jq 'length')" != 1 ]; then
    B_REASON="precondition: expected exactly one live x11vnc, found $vnc_before"
    J_BROWSER_HEALTHY=$(jq -n -c '{captured:false}'); J_BROWSER_POST=$(jq -n -c '{captured:false}')
    finish_baseline "$EX_ENV"
  fi
  local pid; pid=$(printf '%s' "$vnc_before" | jq -r '.[0]')
  local cmdline; cmdline=$(timeout 15 docker exec "$cid" sh -c "tr '\\0' ' ' < /proc/$pid/cmdline" 2>/dev/null)
  local pre_rfb pre_http pre_line
  pre_http=$(http_code "$HTTP_URL"); pre_rfb=$(rfb_json); pre_line=$(container_inspect_line "$cid")
  J_BROWSER_HEALTHY=$(jq -n -c --arg at "$(now_utc)" --argjson page "$(vnc_html_capture)" --argjson rfb "$pre_rfb" \
    '{at:$at, vnc_html:$page, websocket_rfb:$rfb}')
  set -- $pre_line
  local rc0=$2 started0=$3
  J_PRE=$(jq -n -c --arg at "$(now_utc)" --arg cid "$cid" --arg http "$pre_http" --argjson rfb "$pre_rfb" \
    --argjson secs "$READY_SECS" --arg rc "$rc0" --arg st "$started0" --argjson pid "$pid" --arg cmd "$cmdline" \
    --argjson web "$web_before" --argjson stale "$STALE_CLEANED" \
    '{ready:true, at:$at, container_id:$cid, seconds_to_ready:$secs, http_status:($http|tonumber? // 0), rfb:$rfb,
      restart_count:($rc|tonumber), started_at:$st, x11vnc:{pid:$pid, cmdline:$cmd}, websockify_pids:$web,
      fresh_volume:{qa_volume:"'"$QA_VOLUME"'", stale_leftovers_removed_first:$stale}}')
  if [ "$(printf '%s' "$pre_rfb" | jq -r '.ok')" != true ] || [ "$pre_http" != 200 ]; then
    B_REASON="precondition: not healthy immediately before fault injection"; finish_baseline "$EX_ENV"
  fi

  # ---- fault injection: TERM the exact QA x11vnc PID (resolved via exec in the QA container only)
  local t_inject_epoch; t_inject_epoch=$(date +%s)
  log "TERM -> x11vnc pid $pid in $QA_CONTAINER"
  if ! qa_mutate timeout 20 docker exec "$cid" kill -TERM "$pid"; then
    B_REASON="kill -TERM failed"; finish_baseline "$EX_ENV"
  fi
  # wait (bounded) for the signal to take effect
  local dead=false k_deadline=$((SECONDS + 20)) survey
  while :; do
    survey=$(proc_survey "$cid")
    if [ "$(live_pids "$survey" x11vnc | jq --argjson p "$pid" 'index($p) == null')" = true ]; then dead=true; break; fi
    [ "$SECONDS" -ge "$k_deadline" ] && break
    sleep 1
  done
  J_FAULT=$(jq -n -c --argjson pid "$pid" --arg at "$(now_utc)" --argjson dead "$dead" \
    '{signal:"TERM", target:"x11vnc", pid:$pid, container:"'"$QA_CONTAINER"'", injected_at:$at, pid_gone_within_20s:$dead}')
  if [ "$dead" != true ]; then B_REASON="x11vnc survived TERM within 20s"; finish_baseline "$EX_ENV"; fi

  # ---- bounded observation: does anything recover?
  log "observing for up to ${OBSERVE_SECS}s (HTTP / RFB / x11vnc respawn / RestartCount)"
  local samples="$WORK/samples.jsonl"; : >"$samples"
  local t0=$SECONDS recovered=false recovered_why="" http rfb line st rc sa live_v live_w n=0 elapsed
  while :; do
    http=$(http_code "$HTTP_URL"); rfb=$(rfb_json)
    line=$(container_inspect_line "$cid"); sa=$(proc_survey "$cid")
    live_v=$(live_pids "$sa" x11vnc); live_w=$(live_pids "$sa" websockify)
    set -- $line; st=${1:-gone}; rc=${2:-0}; local started=${3:-}
    n=$((n + 1)); elapsed=$((SECONDS - t0))
    jq -n -c --argjson t "$elapsed" --arg at "$(now_utc)" --arg http "$http" --argjson rfb "$rfb" \
      --argjson v "$live_v" --argjson w "$live_w" --arg st "$st" --arg rc "$rc" --arg started "$started" \
      '{t_s:$t, at:$at, http_status:($http|tonumber? // 0), rfb_ok:$rfb.ok, rfb_error:$rfb.error, rfb_banner:$rfb.banner,
        x11vnc_live_pids:$v, websockify_live_pids:$w, container_status:$st, restart_count:($rc|tonumber? // -1), started_at:$started}' >>"$samples"
    if [ "$(printf '%s' "$rfb" | jq -r '.ok')" = true ]; then recovered=true; recovered_why="RFB handshake succeeded again"; fi
    if [ "$(printf '%s' "$live_v" | jq 'length')" != 0 ]; then recovered=true; recovered_why="x11vnc process respawned"; fi
    if [ "$rc" != "$rc0" ] || [ "$started" != "$started0" ] || [ "$st" != running ]; then recovered=true; recovered_why="container restarted/stopped (status=$st restart_count=$rc)"; fi
    $recovered && break
    [ "$elapsed" -ge "$OBSERVE_SECS" ] && break
    sleep "$POLL_INTERVAL"
  done
  local t_end_epoch; t_end_epoch=$(date +%s)
  local events
  events=$(timeout 30 docker events --since "$t_inject_epoch" --until "$t_end_epoch" --filter "container=$cid" --format '{{json .}}' 2>/dev/null \
            | jq -s -c '{exec_events_omitted: (map(select(.Action|startswith("exec_")))|length),
                        lifecycle_events: (map(select(.Action|startswith("exec_")|not) | {action:.Action, time:.time}))}' 2>/dev/null)
  [ -n "$events" ] || events='{"exec_events_omitted":0,"lifecycle_events":[],"note":"docker events unavailable"}'
  J_PROC_AFTER=$(proc_survey "$cid")
  J_BROWSER_POST=$(jq -n -c --arg at "$(now_utc)" --argjson page "$(vnc_html_capture)" --argjson rfb "$(rfb_json)" \
    '{at:$at, vnc_html:$page, websocket_rfb:$rfb}')
  J_OBS=$(jq -s -c --argjson win "$OBSERVE_SECS" --argjson recovered "$recovered" --arg why "$recovered_why" \
    --argjson events "$events" --argjson rc0 "$rc0" '
    { window_requested_s:$win, window_observed_s:(map(.t_s)|max), sample_count:length,
      recovered:$recovered, recovery_reason:$why,
      summary: { http_always_200: (all(.[]; .http_status==200)),
                 rfb_failed_every_sample: (all(.[]; .rfb_ok|not)),
                 x11vnc_never_respawned: (all(.[]; (.x11vnc_live_pids|length)==0)),
                 restart_count_unchanged: (all(.[]; .restart_count==$rc0)),
                 container_running_throughout: (all(.[]; .container_status=="running")),
                 websockify_alive_throughout: (all(.[]; (.websockify_live_pids|length)>0)) },
      docker_events_during_window: $events, samples: . }' "$samples")
  local verdict
  verdict=$(printf '%s' "$J_OBS" | jq -r '
    .summary as $s | if (.recovered|not) and .window_observed_s >= .window_requested_s
      and $s.http_always_200 and $s.rfb_failed_every_sample and $s.x11vnc_never_respawned
      and $s.restart_count_unchanged and $s.container_running_throughout then "reproduced" else "not_reproduced" end')
  if [ "$verdict" = reproduced ]; then
    B_STATUS=defect_reproduced; B_REASON="HTTP 200 persisted while RFB handshake failed in every sample; x11vnc not respawned; RestartCount unchanged"
    finish_baseline "$EX_REPRODUCED"
  else
    B_STATUS=defect_not_reproduced; B_REASON="${recovered_why:-observation did not match the defect signature}"
    finish_baseline "$EX_NOT_REPRODUCED"
  fi
}

############################ up / cleanup ############################

cmd_up() {
  need_tools; resolve_guard; prep_fresh
  qa_up || die_env "compose up failed"
  wait_ready || die_env "$READY_REASON"
  log "QA ready after ${READY_SECS}s: $VNC_URL"
  jq -n -c --arg url "$VNC_URL" --argjson s "$READY_SECS" '{ready:true, url:$url, seconds_to_ready:$s}'
}

cmd_cleanup() {
  need_tools; resolve_guard
  local prefix=${1:-task-1}
  local started; started=$(now_utc)
  log "compose down -v (QA project only)"
  local down_rc=0
  mutant_teardown
  qa_mutate timeout 180 docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans --timeout 30 >&2 || down_rc=$?
  local c v n p1 p2 tag ctag
  c=$(docker ps -a -q --filter "name=^/${QA_CONTAINER}\$" | wc -l)
  v=$(docker volume ls -q --filter "name=^${QA_VOLUME}\$" | wc -l)
  n=$(docker network ls -q --filter "name=^${QA_NETWORK}\$" | wc -l)
  port_busy "$QA_HTTP_PORT" && p1=true || p1=false
  port_busy "$QA_RDP_PORT" && p2=true || p2=false
  tag=$(docker image inspect "$BASELINE_TAG" --format '{{.Id}}' 2>/dev/null || true)
  ctag=$(docker image inspect "kakaotalk-wine:reliability-qa" --format '{{.Id}}' 2>/dev/null || true)
  local prod_after; prod_after=$(prod_snapshot)
  local before=null dir; dir=$(evidence_dir)
  case "$prefix" in
    task-1) [ -f "$dir/task-1-baseline.json" ] && before=$(jq -c '.production.before' "$dir/task-1-baseline.json") ;;
    task-2|task-2-[a-z]) [ -f "$dir/task-2-recovery.json" ] && before=$(jq -c '.production.before' "$dir/task-2-recovery.json") ;;
  esac
  local mtagid mtmp
  mtagid=$(docker image inspect "$MUTANT_TAG" --format '{{.Id}}' 2>/dev/null || true)
  mtmp=$(compgen -G "${TMPDIR:-/tmp}/kakao-mutant.*" | wc -l)
  local ok=false
  [ "$down_rc" = 0 ] && [ "$c" = 0 ] && [ "$v" = 0 ] && [ "$n" = 0 ] && [ "$p1" = false ] && [ "$p2" = false ] && [ -z "$mtagid" ] && [ "$mtmp" = 0 ] && ok=true
  local json outname="$prefix-cleanup.json" taskname="$prefix-cleanup"
  case "$prefix" in task-2-[a-z]) outname="task-2-cleanup-${prefix#task-2-}.json"; taskname="task-2-cleanup-${prefix#task-2-}" ;; esac
  json=$(jq -n -c --arg started "$started" --arg finished "$(now_utc)" --argjson ok "$ok" --argjson down_rc "$down_rc" \
    --argjson c "$c" --argjson v "$v" --argjson n "$n" --argjson p1 "$p1" --argjson p2 "$p2" \
    --arg tag "$BASELINE_TAG" --arg tagid "$tag" --arg ctagid "$ctag" --argjson pa "$prod_after" --argjson pb "$before" \
    --arg mtag "$MUTANT_TAG" --arg mtagid "$mtagid" --argjson mtmp "$mtmp" --argjson src "$(source_light)" \
    --arg qav "$QA_VOLUME" --arg qan "$QA_NETWORK" --arg qac "$QA_CONTAINER" --arg taskname "$taskname" \
    '{task:$taskname, schema:1, command:"docker compose -p kakao-reliability-qa -f docker-compose.qa.yml down -v", source:$src,
      started_at:$started, finished_at:$finished, exit_code:(if $ok then 0 else 2 end), cleanup_verified:$ok,
      compose_down_exit_code:$down_rc,
      removed: {container:$qac, container_remaining:$c, volume:$qav, volume_remaining:$v, network:$qan, network_remaining:$n},
      ports_free: {"24500": ($p1|not), "23389": ($p2|not)},
      baseline_image_kept: {tag:$tag, id:$tagid, present:($tagid != "")},
      candidate_image_kept: {tag:"kakaotalk-wine:reliability-qa", id:$ctagid, present:($ctagid != "")},
      production: { before_run:$pb, now:$pa,
                    unchanged_since_run_start: (($pb != null) and ($pa.found // false) and $pb.id == $pa.id
                        and $pb.started_at == $pa.started_at and $pb.restart_count == $pa.restart_count and $pb.status == $pa.status) },
      mutant:{tag:$mtag, tag_remaining:($mtagid != ""), temp_dir_pattern:"${TMPDIR:-/tmp}/kakao-mutant.*", temp_dirs_remaining:$mtmp},
      note:"production resources are never cleanup targets; only the QA project volume/network/container were removed; baseline and candidate image tags are kept; the mutant QA tag and its temp copies are removed"}')
  write_evidence "$outname" "$json"
  printf '%s\n' "$json" | jq .
  $ok || exit "$EX_ENV"
}

############################ guard self-test ############################

cmd_guard_selftest() {
  need_tools
  local real_docker; real_docker=$(command -v docker)
  local base="$WORK/base.json" stub="$WORK/stub"; mkdir -p "$stub"
  config_json >"$base" || die_env "cannot resolve the real QA config for the self-test"
  cat >"$stub/docker" <<'EOF'
#!/usr/bin/env bash
# self-test stub: logs every docker invocation; only read-only compose config / version pass through
echo "$*" >> "$QA_STUB_LOG"
case "$*" in
  "compose "*" config "*|"version"*) exec "$QA_REAL_DOCKER" "$@";;
esac
echo "stub: docker call blocked: $*" >&2
exit 97
EOF
  chmod +x "$stub/docker"
  local log="$WORK/stub.log"; : >"$log"
  local ev_root; ev_root="$REPO_ROOT/doc/evidence"
  local ev_before; ev_before=$(find "$ev_root" -type f -printf '%p %s %T@\n' 2>/dev/null | sort | sha256sum)

  # detector control: the stub must record a mutating call
  PATH="$stub:$PATH" QA_STUB_LOG="$log" QA_REAL_DOCKER="$real_docker" docker compose -p selftest-control down -v >/dev/null 2>&1
  local control_rc=$? control_logged; control_logged=$(wc -l <"$log"); : >"$log"

  local cases='{
    "container_name_kakaotalk-wine": ".services.kakaotalk.container_name=\"kakaotalk-wine\"",
    "container_name_kakaotalk-web": ".services.kakaotalk.container_name=\"kakaotalk-web\"",
    "volume_kakaotalk-web_kakao-wine-data": ".volumes[\"kakao-qa-data\"].name=\"kakaotalk-web_kakao-wine-data\"",
    "mount_source_production_volume": ".services.kakaotalk.volumes[0].source=\"kakaotalk-web_kakao-wine-data\"",
    "published_port_14500": ".services.kakaotalk.ports[0].published=\"14500\"",
    "published_port_13389": ".services.kakaotalk.ports[1].published=\"13389\"",
    "image_kakaotalk-wine:local": ".services.kakaotalk.image=\"kakaotalk-wine:local\"",
    "project_kakaotalk-web": ".name=\"kakaotalk-web\"",
    "host_bind_mount_added": ".services.kakaotalk.volumes += [{\"type\":\"bind\",\"source\":\"/mnt/c/share\",\"target\":\"/share\"}]",
    "all_production_names_combined": ".name=\"kakaotalk-web\" | .services.kakaotalk.container_name=\"kakaotalk-wine\" | .services.kakaotalk.image=\"kakaotalk-wine:local\" | .services.kakaotalk.ports[0].published=\"14500\" | .services.kakaotalk.ports[1].published=\"13389\" | .volumes[\"kakao-qa-data\"].name=\"kakaotalk-web_kakao-wine-data\""
  }'
  local needles='{
    "container_name_kakaotalk-wine": "container_name kakaotalk-wine intersects production",
    "container_name_kakaotalk-web": "container_name kakaotalk-web intersects production",
    "volume_kakaotalk-web_kakao-wine-data": "volume kakaotalk-web_kakao-wine-data intersects production",
    "mount_source_production_volume": "mount source kakaotalk-web_kakao-wine-data intersects production volume",
    "published_port_14500": "published port 14500 intersects production",
    "published_port_13389": "published port 13389 intersects production",
    "image_kakaotalk-wine:local": "image kakaotalk-wine:local intersects production tag",
    "project_kakaotalk-web": "project name kakaotalk-web intersects production",
    "host_bind_mount_added": "non-volume mount (bind)",
    "all_production_names_combined": "container_name kakaotalk-wine intersects production"
  }'
  local results="$WORK/results.jsonl"; : >"$results"
  local name filter needle sub rc err ncalls seen all_ok=true
  while IFS= read -r name; do
    filter=$(printf '%s' "$cases" | jq -r --arg n "$name" '.[$n]')
    needle=$(printf '%s' "$needles" | jq -r --arg n "$name" '.[$n]')
    jq "$filter" "$base" >"$WORK/case.json" || die_env "self-test case $name did not build"
    for sub in baseline cleanup up build healthy recovery; do
      : >"$log"
      err=$(PATH="$stub:$PATH" QA_SELFTEST=1 QA_SELFTEST_CONFIG="$WORK/case.json" QA_STUB_LOG="$log" QA_REAL_DOCKER="$real_docker" \
            bash "$SCRIPT_PATH" "$sub" 2>&1 >/dev/null); rc=$?
      ncalls=$(wc -l <"$log")
      seen=false; case "$err" in *"$needle"*) seen=true;; esac
      jq -n -c --arg n "$name" --arg sub "$sub" --argjson rc "$rc" --argjson calls "$ncalls" --argjson seen "$seen" --arg needle "$needle" \
        --arg err "$(printf '%s' "$err" | grep -- ' - ' | head -n 4)" \
        '{case:$n, subcommand:$sub, exit_code:$rc, refused:($rc==3), docker_calls_before_refusal:$calls,
          expected_reason:$needle, expected_reason_seen:$seen, violations_excerpt:($err|split("\n"))}' >>"$results"
      { [ "$rc" = 3 ] && [ "$ncalls" = 0 ] && [ "$seen" = true ]; } || all_ok=false
    done
  done < <(printf '%s' "$cases" | jq -r 'keys_unsorted[]')

  # positive control: the real QA config passes the guard (real docker, read-only config call)
  local pos_rc; bash "$SCRIPT_PATH" guard >/dev/null 2>&1; pos_rc=$?
  local ev_after; ev_after=$(find "$ev_root" -type f -printf '%p %s %T@\n' 2>/dev/null | sort | sha256sum)
  local control_ok=false; { [ "$control_rc" = 97 ] && [ "$control_logged" -ge 1 ]; } && control_ok=true
  [ "$pos_rc" = 0 ] || all_ok=false
  [ "$control_ok" = true ] || all_ok=false
  [ "$ev_before" = "$ev_after" ] || all_ok=false
  jq -s -c --argjson all "$all_ok" --argjson pos "$pos_rc" --argjson ctl "$control_ok" --argjson ctlrc "$control_rc" \
    --argjson ctllog "$control_logged" --argjson evsame "$([ "$ev_before" = "$ev_after" ] && echo true || echo false)" \
    '{task:"guard-selftest", all_refused_before_any_docker_call:$all,
      stub_detector_control:{mutating_call_logged_and_blocked:$ctl, stub_exit_code:$ctlrc, logged_calls:$ctllog},
      positive_control_real_config_passes_guard:($pos==0), evidence_dir_untouched_by_refusals:$evsame,
      refusal_exit_code_expected:3, cases:.}' "$results" | tee "$WORK/selftest.json" | jq .
  [ "$all_ok" = true ] || exit "$EX_ENV"
  log "guard-selftest OK: every production-intersecting config was refused with exit 3 and zero docker calls"
}

cmd_guard() {
  need_tools; resolve_guard
  log "guard OK: project=$QA_PROJECT container=$QA_CONTAINER image=$QA_IMAGE"
}

############################ manifest ############################

run_recorded() { # <label> <cmd...> -> appends {command,exit_code} to $WORK/cmds.jsonl
  local label=$1; shift
  local rc=0
  "$@" >"$WORK/out.$$" 2>&1 || rc=$?
  jq -n -c --arg c "$label" --argjson rc "$rc" '{command:$c, exit_code:$rc}' >>"$WORK/cmds.jsonl"
  return 0
}

cmd_manifest() {
  need_tools
  local dir; dir=$(evidence_dir); mkdir -p "$dir"
  : >"$WORK/cmds.jsonl"
  ( cd "$REPO_ROOT" || exit 2
    run_recorded "bash -n scripts/qa-runtime.sh" bash -n scripts/qa-runtime.sh
    run_recorded "bash -n docker/entrypoint.sh" bash -n docker/entrypoint.sh
    run_recorded "bash -n docker/run-kakao.sh" bash -n docker/run-kakao.sh
    run_recorded "bash -n docker/healthcheck.sh" bash -n docker/healthcheck.sh
    run_recorded "docker compose -p kakao-reliability-qa -f docker-compose.qa.yml config --quiet" docker compose -p "$QA_PROJECT" -f docker-compose.qa.yml config --quiet
    run_recorded "docker compose -f docker-compose.yml config --quiet" docker compose -f docker-compose.yml config --quiet )
  local st_rc=0
  bash "$SCRIPT_PATH" guard-selftest >"$WORK/selftest.out" 2>/dev/null || st_rc=$?
  jq -n -c --argjson rc "$st_rc" '{command:"bash scripts/qa-runtime.sh guard-selftest", exit_code:$rc}' >>"$WORK/cmds.jsonl"
  local selftest; selftest=$(jq -c . "$WORK/selftest.out" 2>/dev/null || echo null)

  local files="[]" f
  while IFS= read -r f; do
    [ "$f" = "${dir#"$REPO_ROOT"/}/manifest.json" ] && continue
    files=$(printf '%s' "$files" | jq -c --arg p "$f" --arg s "$(sha_of "$REPO_ROOT/$f")" --arg z "$(wc -c <"$REPO_ROOT/$f")" \
      '. + [{path:$p, sha256:$s, bytes:($z|tonumber)}]')
  done < <(git -C "$REPO_ROOT" ls-files --others --exclude-standard)

  local task_cmds="[]" t evfiles="[]"
  for t in "$dir"/task-*.json; do
    [ -f "$t" ] || continue
    evfiles=$(printf '%s' "$evfiles" | jq -c --arg n "$(basename "$t")" '. + [$n]')
    task_cmds=$(printf '%s' "$task_cmds" | jq -c --slurpfile j "$t" \
      '. + [{file:input_filename, command:($j[0].command // null), exit_code:($j[0].exit_code // null), started_at:($j[0].started_at // null), finished_at:($j[0].finished_at // null)}]' 2>/dev/null \
      || printf '%s' "$task_cmds")
  done
  evfiles=$(printf '%s' "$evfiles" | jq -c '. + ["manifest.json"]')

  local qa_img local_img base_img
  qa_img=$(docker image inspect kakaotalk-wine:reliability-qa --format '{{.Id}}' 2>/dev/null || true)
  local_img=$(docker image inspect "$PROD_IMAGE_TAG" --format '{{.Id}}' 2>/dev/null || true)
  base_img=$(docker image inspect "$BASELINE_TAG" --format '{{.Id}}' 2>/dev/null || true)

  local facts=null prod_cmp=null cand_facts=null
  [ -f "$dir/task-1-baseline.json" ] && facts=$(jq -c '.image_facts_baseline' "$dir/task-1-baseline.json")
  [ -f "$dir/task-1-baseline.json" ] && prod_cmp=$(jq -c '.production' "$dir/task-1-baseline.json")
  [ -f "$dir/task-2-build.json" ] && cand_facts=$(jq -c '{baseline:.image_facts.baseline, candidate:.image_facts.candidate, comparison:.image_facts.comparison}' "$dir/task-2-build.json")

  local json
  json=$(jq -n -c \
    --arg gen "$(now_utc)" --argjson src "$(source_info)" --argjson wt "$(worktree_state)" \
    --argjson files "$files" --argjson cmds "$(jq -s -c . "$WORK/cmds.jsonl")" --argjson taskcmds "$task_cmds" \
    --arg dv "$(docker version --format '{{.Client.Version}}' 2>/dev/null)" --arg ds "$(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
    --arg cv "$(docker compose version --short 2>/dev/null)" --arg jqv "$(jq --version)" --arg bashv "$BASH_VERSION" \
    --arg pyv "$(python3 --version 2>&1)" \
    --arg base "$base_img" --arg loc "$local_img" --arg qai "$qa_img" --arg prodcid "$(docker inspect "$PROD_CONTAINER" --format '{{.Image}}' 2>/dev/null)" \
    --argjson facts "$facts" --argjson candfacts "$cand_facts" --argjson prodcmp "$prod_cmp" --argjson selftest "$selftest" --arg dir "${dir#"$REPO_ROOT"/}" \
    --argjson evfiles "$evfiles" --arg untracked_sha "$(untracked_sha256)" \
    '{ task:"manifest", schema:2, generated_at:$gen, evidence_dir:$dir,
       tested_source: { revision:$src.revision, short:$src.short, branch:$src.branch,
                        git_diff_binary_sha256:$src.git_diff_binary_sha256,
                        git_diff_note:"hash of tracked changes only (git diff --binary); new files are bound by untracked_files below",
                        untracked_files_combined_sha256:$untracked_sha,
                        worktree_status_excluding_evidence:$wt.status_excluding_evidence },
       untracked_files: $files,
       untracked_files_note: "sha256 of every new/untracked file at manifest time; manifest.json itself excluded",
       source_verification: $src,
       images: { baseline_tag:{tag:"kakaotalk-wine:reliability-baseline", id:$base}, production_tag:{tag:"kakaotalk-wine:local", id:$loc},
                 production_container_image_id:$prodcid, candidate_tag:{tag:"kakaotalk-wine:reliability-qa", id:(if $qai=="" then null else $qai end)},
                 baseline_identical_to_production: ($base == $prodcid and $base == $loc) },
       baseline_image_facts: $facts,
       candidate_vs_baseline_image_facts: $candfacts,
       versions: { docker_client:$dv, docker_server:$ds, docker_compose:$cv, jq:$jqv, bash:$bashv, python:$pyv },
       commands: ($cmds + $taskcmds),
       guard_selftest: $selftest,
       production_comparison: $prodcmp,
       evidence_files: $evfiles }') \
    || die_env "failed to assemble manifest"
  write_evidence manifest.json "$json"
}

############################ todo 2: candidate image ############################

CANDIDATE_TAG=kakaotalk-wine:reliability-qa
RECOVERY_DEADLINE="${QA_RECOVERY_DEADLINE:-240}"
WINDOW_DEADLINE="${QA_WINDOW_DEADLINE:-90}"
HEALTHY_OBSERVE="${QA_HEALTHY_OBSERVE:-45}"
GRACE_WAIT_MAX=150
RECOVERY_CASES="app xvfb x11vnc websockify freeze stop"
HC_IN_CONTAINER=/usr/local/bin/kakao-healthcheck

use_candidate() { QA_IMAGE=$CANDIDATE_TAG; export QA_IMAGE; }

img_id() { docker image inspect "$1" --format '{{.Id}}' 2>/dev/null || true; }

kvget() { # <record> <key>
  local rec=" $1 " k=$2 v
  v=${rec#* "$k"=}
  [ "$v" = "$rec" ] && return 1
  printf '%s' "${v%% *}"
}

wt_script_hashes() {
  jq -n -c --arg e "$(sha_of "$REPO_ROOT/docker/entrypoint.sh")" --arg r "$(sha_of "$REPO_ROOT/docker/run-kakao.sh")" \
    --arg h "$(sha_of "$REPO_ROOT/docker/healthcheck.sh")" '{entrypoint:$e, runner:$r, healthcheck:$h}'
}

candidate_embedded_hashes() {
  qa_mutate timeout 60 docker run --rm --network none --entrypoint sha256sum "$CANDIDATE_TAG" \
      /usr/local/bin/kakao-entrypoint /usr/local/bin/run-kakao /usr/local/bin/kakao-healthcheck 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length>0) | split("  ") | {(.[1]): .[0]}) | add // {}
                   | {entrypoint:.["/usr/local/bin/kakao-entrypoint"], runner:.["/usr/local/bin/run-kakao"], healthcheck:.["/usr/local/bin/kakao-healthcheck"]}'
}

candidate_current() { # 0 when the candidate image exists and embeds exactly the worktree scripts
  [ -n "$(img_id "$CANDIDATE_TAG")" ] || return 1
  [ "$(candidate_embedded_hashes)" = "$(wt_script_hashes)" ]
}

untracked_sha256() { # combined hash of untracked, non-evidence files (new files are not part of git diff)
  ( cd "$REPO_ROOT" && git ls-files --others --exclude-standard | grep -v '^doc/evidence/' | sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1 )
}

source_light() {
  jq -n -c --arg head "$(git -C "$REPO_ROOT" rev-parse HEAD)" --arg short "$(git -C "$REPO_ROOT" rev-parse --short HEAD)" \
    --arg branch "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)" \
    --arg diff "$(git -C "$REPO_ROOT" diff --binary | sha256sum | cut -d' ' -f1)" --arg untracked "$(untracked_sha256)" \
    --argjson wt "$(wt_script_hashes)" --argjson emb "$(candidate_embedded_hashes)" \
    --arg seed "${QA_APP_SEED_DIR:-}" --arg seedexe "$([ -n "${QA_APP_SEED_DIR:-}" ] && sha_of "$QA_APP_SEED_DIR/KakaoTalk.exe")" \
    '{revision:$head, short:$short, branch:$branch, git_diff_binary_sha256:$diff, untracked_files_combined_sha256:$untracked,
      scripts_worktree:$wt, scripts_embedded_in_candidate:$emb, candidate_embeds_worktree_scripts:($wt == $emb),
      qa_app_seed:(if $seed == "" then {used:false, note:"image-bundled KakaoTalk (stale on a fresh volume: error dialog, not login)"} else {used:true, kakaotalk_exe_sha256:$seedexe, note:"opt-in fixture: production app binaries copied into the QA container, no user data"} end)}'
}

facts_compare() { # <baseline facts json> <candidate facts json>
  jq -n -c --argjson b "$1" --argjson c "$2" '{
    wine_version_same: ($b.wine.version == $c.wine.version),
    kakaotalk_exe_sha256_same: ($b.kakaotalk.exe_sha256 == $c.kakaotalk.exe_sha256),
    kakaotalk_version_same: ($b.kakaotalk.version_from_changelog == $c.kakaotalk.version_from_changelog),
    packages_same: ($b.packages == $c.packages),
    wine: {baseline:$b.wine.version, candidate:$c.wine.version},
    kakaotalk: {baseline:{version:$b.kakaotalk.version_from_changelog, exe_sha256:$b.kakaotalk.exe_sha256},
                candidate:{version:$c.kakaotalk.version_from_changelog, exe_sha256:$c.kakaotalk.exe_sha256}},
    lifecycle_scripts_differ_as_expected: ($b.scripts_in_container.entrypoint != $c.scripts_in_container.entrypoint)}'
}

BUILD_BASELINE_BEFORE=""; BUILD_BASELINE_AFTER=""
build_candidate() {
  BUILD_BASELINE_BEFORE=$(img_id "$BASELINE_TAG")
  [ -n "$BUILD_BASELINE_BEFORE" ] || die_env "baseline tag $BASELINE_TAG missing (docker tag $PROD_IMAGE_ID_EXPECT $BASELINE_TAG)"
  use_candidate
  log "building candidate $CANDIDATE_TAG = FROM $BASELINE_TAG + COPY scripts (no apt, no pull)"
  qa_mutate timeout 900 docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" build >&2 || die_env "candidate build failed"
  BUILD_BASELINE_AFTER=$(img_id "$BASELINE_TAG")
  [ "$BUILD_BASELINE_BEFORE" = "$BUILD_BASELINE_AFTER" ] || die_env "BASELINE TAG CHANGED during build: $BUILD_BASELINE_BEFORE -> $BUILD_BASELINE_AFTER"
}

ensure_candidate() {
  candidate_current || build_candidate
  candidate_current || die_env "candidate image does not embed the worktree scripts"
}

cmd_build() {
  need_tools; resolve_guard
  local started; started=$(now_utc)
  local base_before; base_before=$(img_id "$BASELINE_TAG")
  [ -n "$base_before" ] || die_env "baseline tag $BASELINE_TAG missing"
  # negative control: building while QA_IMAGE is the baseline tag must be refused by the inline Dockerfile
  log "negative control: build with QA_IMAGE=$BASELINE_TAG must fail and leave the baseline tag untouched"
  local neg_out neg_rc=0
  neg_out=$(QA_IMAGE=$BASELINE_TAG qa_mutate timeout 300 docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" build 2>&1) || neg_rc=$?
  local base_after_neg; base_after_neg=$(img_id "$BASELINE_TAG")
  build_candidate
  local cand; cand=$(img_id "$CANDIDATE_TAG")
  [ -n "$cand" ] || die_env "candidate image missing after build"
  local fb fc cmp emb wt
  fb=$(image_facts_for "$BASELINE_TAG"); fc=$(image_facts_for "$CANDIDATE_TAG")
  [ -n "$fb" ] && [ -n "$fc" ] || die_env "could not collect image facts"
  cmp=$(facts_compare "$fb" "$fc")
  emb=$(candidate_embedded_hashes); wt=$(wt_script_hashes)
  local ok=false
  printf '%s' "$cmp" | jq -e '.wine_version_same and .kakaotalk_exe_sha256_same and .kakaotalk_version_same and .packages_same and .lifecycle_scripts_differ_as_expected' >/dev/null \
    && [ "$neg_rc" != 0 ] && [ "$base_before" = "$base_after_neg" ] && [ "$BUILD_BASELINE_BEFORE" = "$BUILD_BASELINE_AFTER" ] \
    && [ "$emb" = "$wt" ] && ok=true
  local json
  json=$(jq -n -c --arg started "$started" --arg finished "$(now_utc)" --argjson ok "$ok" \
    --arg bb "$base_before" --arg bn "$base_after_neg" --arg ba "$BUILD_BASELINE_AFTER" --arg cand "$cand" \
    --argjson negrc "$neg_rc" --arg negout "$(printf '%s' "$neg_out" | tail -n 6)" \
    --argjson fb "$fb" --argjson fc "$fc" --argjson cmp "$cmp" --argjson emb "$emb" --argjson wt "$wt" --argjson src "$(source_light)" \
    '{task:"task-2-build", schema:1, command:"bash scripts/qa-runtime.sh build", started_at:$started, finished_at:$finished,
      exit_code:(if $ok then 0 else 2 end), passed:$ok,
      source:$src,
      baseline_protection: {baseline_id_before:$bb, after_negative_control:$bn, after_candidate_build:$ba,
                            negative_control_exit_code:$negrc, negative_control_output_tail:($negout|split("\n")),
                            baseline_tag_never_overwritten: ($bb == $bn and $bb == $ba), negative_control_refused: ($negrc != 0)},
      candidate: {tag:"kakaotalk-wine:reliability-qa", id:$cand, definition:"docker-compose.qa.yml dockerfile_inline: FROM kakaotalk-wine:reliability-baseline + COPY entrypoint/run-kakao/healthcheck + HEALTHCHECK; no apt/pull"},
      image_facts: {baseline:$fb, candidate:$fc, comparison:$cmp},
      scripts: {worktree:$wt, embedded_in_candidate:$emb, match:($wt == $emb)}}') || die_env "failed to assemble build JSON"
  write_evidence task-2-build.json "$json"
  printf '%s\n' "$json" | jq '{passed, baseline_protection, comparison:.image_facts.comparison}'
  $ok || exit "$EX_ENV"
}

############################ todo 2: runtime probes ############################

pidmap() { # <survey json> -> pids per layer (non-zombie)
  printf '%s' "$1" | jq -c '
    def l($c): [.[] | select(.comm==$c and .state!="Z" and .state!="X") | .pid] | sort;
    {xvfb:l("Xvfb"), openbox:l("openbox"), x11vnc:l("x11vnc"), websockify:l("websockify"), app:l("KakaoTalk.exe"),
     entrypoint:([.[] | select((.comm|startswith("kakao-entrypoi")) and .state!="Z" and .state!="X") | .pid] | sort)}'
}

PROBE_OUT=""; PROBE_RC=1
probe_json() { # one real probe through docker exec (the same script Docker HEALTHCHECK runs)
  local ph ly rs
  PROBE_OUT=$(timeout 30 docker exec "$QA_CONTAINER" "$HC_IN_CONTAINER" 2>/dev/null)
  PROBE_RC=$?
  PROBE_OUT=$(printf '%s' "$PROBE_OUT" | head -n 1)
  ph=$(kvget "$PROBE_OUT" phase); ly=$(kvget "$PROBE_OUT" layer); rs=$(kvget "$PROBE_OUT" reason)
  jq -n -c --argjson rc "$PROBE_RC" --arg rec "$PROBE_OUT" --arg ph "${ph:-unreachable}" --arg ly "$ly" --arg rs "$rs" \
    '{rc:$rc, phase:$ph, layer:$ly, reason:$rs, record:$rec}'
}

take_sample() { # <t0 SECONDS value> -> one JSON object: probe + HTTP + WS RFB + container + pids
  local t0=$1 probe http rfb line st rcn started survey
  probe=$(probe_json)
  http=$(http_code "$HTTP_URL"); rfb=$(rfb_json)
  line=$(container_inspect_line "$QA_CONTAINER"); set -- $line
  st=${1:-gone}; rcn=${2:--1}; started=${3:-}
  survey=$(proc_survey "$QA_CONTAINER"); [ -n "$survey" ] || survey='[]'
  jq -n -c --argjson t "$((SECONDS - t0))" --arg at "$(now_utc)" --argjson probe "$probe" --arg http "$http" --argjson rfb "$rfb" \
    --arg st "$st" --arg rc "$rcn" --arg started "$started" --argjson pids "$(pidmap "$survey")" --argjson survey "$survey" \
    '{t_s:$t, at:$at, probe:$probe, http_status:($http|tonumber? // 0), rfb_ok:$rfb.ok, rfb_error:$rfb.error,
      container_status:$st, restart_count:($rc|tonumber? // -1), started_at:$started, pids:$pids,
      stopped_pids:([$survey[] | select(.state=="T") | .pid])}'
}

sample_ready() { printf '%s' "$1" | jq -e '.probe.rc==0 and .probe.phase=="ready" and .http_status==200 and .rfb_ok==true' >/dev/null 2>&1; }

wait_runtime_ready() { # fresh boot: probe ready + HTTP 200 + WS RFB banner, bounded
  local start=$SECONDS deadline=$((SECONDS + READY_TIMEOUT)) st s
  while :; do
    st=$(docker inspect "$QA_CONTAINER" --format '{{.State.Status}}' 2>/dev/null || true)
    case "$st" in exited|dead|removing|restarting|"") READY_REASON="container state '${st:-missing}' while waiting"; return 1;; esac
    s=$(take_sample "$SECONDS")
    if sample_ready "$s"; then READY_SECS=$((SECONDS - start)); return 0; fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      READY_REASON="not ready within ${READY_TIMEOUT}s (last probe: $(printf '%s' "$s" | jq -r '.probe.record'))"; return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

# Grace is wall-clock behavior of the monitor (probe failures only act after startup grace), so waiting for it is
# waiting for time itself; it is bounded and driven by the state file, not a fixed guess.
wait_past_grace() {
  local dl=$((SECONDS + GRACE_WAIT_MAX)) out gu now nap_s
  while :; do
    out=$(timeout 20 docker exec "$QA_CONTAINER" sh -c 'echo "$(grep -m1 "^grace_until=" /data/runtime-state/state | cut -d= -f2) $(date +%s)"' 2>/dev/null)
    set -- $out; gu=${1:-}; now=${2:-}
    if [ -n "$gu" ] && [ -n "$now" ] && [ "$now" -gt "$gu" ] 2>/dev/null; then return 0; fi
    [ "$SECONDS" -ge "$dl" ] && return 1
    nap_s=2
    if [ -n "$gu" ] && [ -n "$now" ]; then nap_s=$((gu - now + 1)); [ "$nap_s" -gt 10 ] && nap_s=10; [ "$nap_s" -lt 1 ] && nap_s=1; fi
    sleep "$nap_s"
  done
}

# A KakaoTalk top-level window counts as the login/main UI only when its client geometry reaches the login window size
# (observed 330x305). The fresh-volume error dialog is 322x89: same class, so class counting alone cannot tell them apart.
UI_MIN_W="${QA_UI_MIN_W:-300}"
UI_MIN_H="${QA_UI_MIN_H:-250}"
kakao_windows() { # class/count/geometry only: window titles never leave the container
  local geo xd
  geo=$(timeout 20 docker exec "$QA_CONTAINER" sh -c "wmctrl -lxG 2>/dev/null | awk '{print \$5, \$6, \$7}'" 2>/dev/null)
  xd=$(timeout 20 docker exec "$QA_CONTAINER" sh -c "xdotool search --onlyvisible --class kakaotalk 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r\n')
  printf '%s\n' "$geo" | jq -R -s -c --arg xd "${xd:-0}" --argjson mw "$UI_MIN_W" --argjson mh "$UI_MIN_H" '
    split("\n") | map(select(length>0) | split(" ") | select(length>=3) | {w:(.[0]|tonumber? // 0), h:(.[1]|tonumber? // 0), class:.[2]}) as $all
    | ($all | map(select(.class|test("kakao";"i")))) as $k
    | ($k | map(select(.w >= $mw and .h >= $mh))) as $ui
    | ($k | map(select(.w < $mw or .h < $mh))) as $small
    | {wmctrl_top_level_windows:($all|length), kakaotalk_class_windows:($k|length), kakaotalk_classes:($k|map(.class)|unique),
       kakaotalk_geometries:($k|map({w,h})), largest_kakaotalk_window:($k|max_by(.w*.h)|if . then {w,h} else null end),
       login_ui_windows:($ui|length), dialog_sized_windows:($small|length), min_login_size:{w:$mw,h:$mh},
       login_ui_present:(($ui|length) > 0), only_dialog_sized:(($k|length) > 0 and ($ui|length) == 0),
       xdotool_visible_class_matches:($xd|tonumber? // 0), titles_logged:false}'
}

WINDOW_JSON=null
wait_window() { # bounded: the KakaoTalk login/main window (login-sized, not an error dialog) exists
  local dl=$((SECONDS + WINDOW_DEADLINE)) start=$SECONDS
  while :; do
    WINDOW_JSON=$(kakao_windows)
    if printf '%s' "$WINDOW_JSON" | jq -e '.login_ui_present == true' >/dev/null 2>&1; then
      WINDOW_JSON=$(printf '%s' "$WINDOW_JSON" | jq -c --argjson s "$((SECONDS - start))" '. + {seconds_waited:$s}'); return 0
    fi
    [ "$SECONDS" -ge "$dl" ] && return 1
    sleep "$POLL_INTERVAL"
  done
}

health_status() { docker inspect "$QA_CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null; }

HEALTH_FINAL=""
wait_health() { # <deadline-s>: wait for Docker health status healthy
  local dl=$((SECONDS + $1))
  while :; do
    HEALTH_FINAL=$(health_status)
    [ "$HEALTH_FINAL" = healthy ] && return 0
    [ "$SECONDS" -ge "$dl" ] && return 1
    sleep "$POLL_INTERVAL"
  done
}

runtime_state_json() { # the monitor's own state files (our records only: no titles/env/secrets)
  timeout 25 docker exec "$QA_CONTAINER" sh -c '
    d=/data/runtime-state
    sed "s/^/S:/" $d/state 2>/dev/null
    sed "s/^/B:/" $d/budget.log 2>/dev/null
    tail -n 40 $d/last-failure.log 2>/dev/null | sed "s/^/L:/"
    echo "Z:$(stat -c %s $d/last-failure.log 2>/dev/null)"
    if test -f /data/wineprefix/.initialized; then echo M:present; else echo M:absent; fi
    echo "P:$(stat -c %a $d)"
    ls -1 $d | sed "s/^/F:/"' 2>/dev/null \
    | jq -R -s -c '
      split("\n") | map(select(length>0)) as $l
      | { state: ([$l[] | select(startswith("S:")) | .[2:] | split("=") | {(.[0]): (.[1:] | join("="))}] | add // {}),
          budget_entries: [$l[] | select(startswith("B:")) | .[2:]],
          failure_log_tail: [$l[] | select(startswith("L:")) | .[2:]],
          failure_log_bytes: (([$l[] | select(startswith("Z:")) | .[2:]] | first // "") | tonumber? // null),
          wine_initialized_marker: (([$l[] | select(startswith("M:")) | .[2:]] | first) // null),
          state_dir_mode: (([$l[] | select(startswith("P:")) | .[2:]] | first) // null),
          state_dir_files: [$l[] | select(startswith("F:")) | .[2:]] }'
}

runtime_log_lines() { # [kakao-runtime] stdout lines (phase/layer/reason/time/recovery-count records only)
  timeout 30 docker logs "$QA_CONTAINER" 2>&1 | grep -a '\[kakao-runtime\]' | tail -n 60 \
    | jq -R -s -c 'split("\n") | map(select(length>0))'
}

stack_fresh_ready() { # fresh QA volume (prep_fresh removes leftovers), candidate image, wait ready
  STALE_CLEANED=false
  prep_fresh
  qa_up || { READY_REASON="compose up failed"; return 1; }
  CASE_CID=$(docker inspect "$QA_CONTAINER" --format '{{.Id}}' 2>/dev/null)
  [ -n "$CASE_CID" ] || { READY_REASON="QA container missing after up"; return 1; }
  [ "$(qa_label_project container "$QA_CONTAINER")" = "$QA_PROJECT" ] || { READY_REASON="QA container lacks QA project label"; return 1; }
  wait_runtime_ready
}

case_error() { # <case> <reason>: JSON for a case that could not run
  jq -n -c --arg c "$1" --arg r "$2" --argjson src "$SRC_JSON" '{case:$c, passed:false, error:$r, source:$src}'
}

pids_gone() { # <cid> <pids json> -> 0 when none of the listed PIDs is alive
  local s; s=$(proc_survey "$1")
  [ "$(live_pids "$s" "$2" | jq 'length')" = 0 ]
}

# Run one single-fault recovery case. Prints the case JSON on stdout (runs in a subshell).
run_fault_case() { # <name>
  local name=$1 comm key sig restart=false freeze=false
  case "$name" in
    app) comm="KakaoTalk.exe"; key=app; sig=TERM ;;
    xvfb) comm=Xvfb; key=xvfb; sig=TERM; restart=true ;;
    x11vnc) comm=x11vnc; key=x11vnc; sig=TERM ;;
    websockify) comm=websockify; key=websockify; sig=TERM ;;
    freeze) comm=x11vnc; key=x11vnc; sig=STOP; freeze=true ;;
    *) case_error "$name" "unknown case"; return 0 ;;
  esac
  local started; started=$(now_utc)
  log "case $name: fresh volume, candidate image, wait ready"
  if ! stack_fresh_ready; then case_error "$name" "precondition: $READY_REASON"; return 0; fi
  local cid=$CASE_CID
  if [ "$freeze" = true ] && ! wait_past_grace; then case_error "$name" "startup grace did not end"; return 0; fi
  wait_window || true
  local win_pre=$WINDOW_JSON
  local survey0 pids0 line rc0 started0 pre_sample img_cid0
  survey0=$(proc_survey "$cid"); pids0=$(pidmap "$survey0")
  line=$(container_inspect_line "$cid"); set -- $line; rc0=${2:-0}; started0=${3:-}
  img_cid0=$(docker inspect "$cid" --format '{{.Image}}' 2>/dev/null)
  pre_sample=$(take_sample "$SECONDS")
  if ! sample_ready "$pre_sample"; then case_error "$name" "precondition: not ready immediately before injection"; return 0; fi
  local targets; targets=$(printf '%s' "$pids0" | jq -c --arg k "$key" '.[$k]')
  if [ "$(printf '%s' "$targets" | jq 'length')" -lt 1 ]; then case_error "$name" "no live $comm process found to fault"; return 0; fi

  # ---- fault injection: signal the exact QA PIDs only (inside the QA container)
  local T0=$SECONDS inject_epoch inject_at pid inj_ok=true escalated=false stopped_confirmed=null
  inject_epoch=$(date +%s); inject_at=$(now_utc)
  for pid in $(printf '%s' "$targets" | jq -r '.[]'); do
    log "$sig -> $comm pid $pid in $QA_CONTAINER"
    qa_mutate timeout 20 docker exec "$cid" kill -"$sig" "$pid" || inj_ok=false
  done
  if [ "$sig" = TERM ] && [ "$restart" != true ]; then
    local kd=$((SECONDS + 20))
    until pids_gone "$cid" "$comm" || [ "$SECONDS" -ge "$kd" ]; do sleep 1; done
    if ! pids_gone "$cid" "$comm" && printf '%s' "$(live_pids "$(proc_survey "$cid")" "$comm")" | jq -e --argjson o "$targets" 'any(.[]; . as $p | $o | index($p) != null)' >/dev/null; then
      for pid in $(printf '%s' "$targets" | jq -r '.[]'); do qa_mutate timeout 20 docker exec "$cid" kill -KILL "$pid" || true; done
      escalated=true
    fi
  fi
  if [ "$sig" = STOP ]; then
    stopped_confirmed=$(proc_survey "$cid" | jq -c --argjson o "$targets" '[.[] | select(.state=="T") | .pid] as $t | ($o | all(. as $p | $t | index($p) != null))')
  fi

  # ---- measure: injection -> probe ready + WS RFB banner, bounded
  local samples="$WORK/samples.$name.jsonl"; : >"$samples"
  local recovered=false rec_s=null s
  while :; do
    s=$(take_sample "$T0"); printf '%s\n' "$s" >>"$samples"
    if printf '%s' "$s" | jq -e --arg k "$key" --argjson old "$pids0" --argjson rc0 "${rc0:-0}" --argjson restart "$restart" '
         (.probe.rc==0 and .probe.phase=="ready" and .http_status==200 and .rfb_ok==true) and
         (if $restart then (.restart_count > $rc0)
          else ((.pids[$k] | length) > 0 and ((.pids[$k] - $old[$k]) | length) == (.pids[$k] | length)) end)' >/dev/null 2>&1; then
      recovered=true; rec_s=$((SECONDS - T0)); break
    fi
    [ $((SECONDS - T0)) -ge "$RECOVERY_DEADLINE" ] && break
    sleep "$POLL_INTERVAL"
  done
  log "case $name: recovered=$recovered after ${rec_s}s"

  # ---- after recovery: window, health, state, other layers
  local rfb_post survey1 pids1 line1 rc1 started1 cid1 img_cid1 win_post state logs
  survey1=$(proc_survey "$cid"); pids1=$(pidmap "$survey1")
  rfb_post=$(rfb_json)
  if [ "$recovered" = true ]; then wait_window || true; else WINDOW_JSON=$(kakao_windows); fi
  win_post=$WINDOW_JSON
  wait_health 90 || true
  line1=$(container_inspect_line "$QA_CONTAINER"); set -- $line1; rc1=${2:--1}; started1=${3:-}
  cid1=$(docker inspect "$QA_CONTAINER" --format '{{.Id}}' 2>/dev/null)
  img_cid1=$(docker inspect "$QA_CONTAINER" --format '{{.Image}}' 2>/dev/null)
  state=$(runtime_state_json); [ -n "$state" ] || state=null
  logs=$(runtime_log_lines); [ -n "$logs" ] || logs='[]'

  jq -n -c --arg name "$name" --arg comm "$comm" --arg key "$key" --arg sig "$sig" --argjson restart "$restart" --argjson freeze "$freeze" \
    --arg started "$started" --arg finished "$(now_utc)" --arg inject_at "$inject_at" --argjson deadline "$RECOVERY_DEADLINE" \
    --argjson recovered "$recovered" --argjson rec_s "$rec_s" --argjson targets "$targets" --argjson inj_ok "$inj_ok" \
    --argjson escalated "$escalated" --argjson stopped_confirmed "$stopped_confirmed" \
    --argjson pids0 "$pids0" --argjson pids1 "$pids1" --argjson rc0 "${rc0:-0}" --argjson rc1 "${rc1:--1}" \
    --arg cid0 "$cid" --arg cid1 "$cid1" --arg started0 "$started0" --arg started1 "$started1" \
    --arg img0 "$img_cid0" --arg img1 "$img_cid1" --arg health "$HEALTH_FINAL" \
    --argjson win_pre "$win_pre" --argjson win_post "$win_post" --argjson rfb_post "$rfb_post" \
    --argjson state "$state" --argjson logs "$logs" --argjson pre "$pre_sample" --slurpfile samples "$samples" \
    --argjson src "$SRC_JSON" --arg base_id "$(img_id "$BASELINE_TAG")" --arg cand_id "$(img_id "$CANDIDATE_TAG")" --arg under_id "$(img_id "${CASE_IMAGE_TAG:-$CANDIDATE_TAG}")" --arg under_tag "${CASE_IMAGE_TAG:-$CANDIDATE_TAG}" \
    '
    ([$key] | . as $f | ["xvfb","openbox","x11vnc","websockify","app","entrypoint"] - $f
      | if $key == "app" then . - ["openbox"] else . end) as $others
    | (($pids0.openbox | length) > 0 and (($pids1.openbox | length) == 0 or (($pids1.openbox - $pids0.openbox) | length) > 0)) as $openbox_changed
    | ($samples | map(select(.probe.phase=="degraded" and .probe.layer=="vnc")) | length > 0) as $saw_degraded_vnc
    | ($samples | map(select(.http_status==200 and .rfb_ok==false)) | length > 0) as $saw_http200_while_rfb_dead
    | ($state.budget_entries // []) as $bud
    | {
      case:$name, started_at:$started, finished_at:$finished,
      fault: {target:$comm, signal:$sig, pids:$targets, injected_at:$inject_at, injection_ok:$inj_ok, escalated_to_kill:$escalated,
              stopped_state_confirmed:$stopped_confirmed, expected_full_restart:$restart},
      source:$src, images:{baseline_tag_id:$base_id, candidate_tag_id:$cand_id, image_under_test_tag:$under_tag, image_under_test_id:$under_id, container_image_id_before:$img0, container_image_id_after:$img1,
                           container_runs_candidate:($img0 == $cand_id), container_runs_image_under_test:($img0 == $under_id)},
      container:{id_before:$cid0, id_after:$cid1, restart_count_before:$rc0, restart_count_after:$rc1, started_at_before:$started0, started_at_after:$started1},
      pids_before:$pids0, pids_after:$pids1,
      pre_fault_sample:$pre, kakaotalk_window_before:$win_pre, kakaotalk_window_after:$win_post, rfb_after:$rfb_post,
      docker_health_after:$health, runtime_state_after:$state, runtime_log_lines:$logs,
      samples:$samples,
      observations:{degraded_vnc_phase_seen:$saw_degraded_vnc, http200_while_rfb_dead_seen:$saw_http200_while_rfb_dead,
                    openbox_replaced:(if $key == "app" then $openbox_changed else null end),
                    openbox_replaced_reason:(if $key == "app" then "orchestrator decision: app relaunch may replace openbox because a relaunched KakaoTalk login window stays unmapped under the old openbox; openbox is therefore excluded from the app-case unchanged-PID equality (xvfb, x11vnc, websockify, entrypoint, container id and RestartCount are still asserted unchanged)" else null end)},
      assertions: {
        recovered_with_probe_ready_and_rfb_ok: $recovered,
        seconds_from_injection_to_ready_and_rfb: $rec_s,
        within_deadline: ($recovered and $rec_s <= $deadline),
        container_id_unchanged: ($cid0 == $cid1),
        restart_count_as_expected: (if $restart then ($rc1 == $rc0 + 1) else ($rc1 == $rc0) end),
        other_layers_unchanged: (if $restart then null else ($others | all(. as $o | (($pids0[$o] - $pids1[$o]) | length) == 0)) end),
        faulted_layer_has_new_pids: ($pids1[$key] | length > 0 and (($pids1[$key] - $pids0[$key]) | length) == ($pids1[$key] | length)),
        kakaotalk_window_present_after: ($win_post.kakaotalk_class_windows > 0),
        kakaotalk_login_ui_not_error_dialog_after: (($win_post.login_ui_present // false) == true),
        docker_health_healthy_after: ($health == "healthy"),
        budget_entries_exactly_one: (($bud | length) == 1),
        container_runs_candidate_image: ($img0 == $under_id and $img1 == $under_id),
        degraded_vnc_observed_when_frozen: (if $freeze then $saw_degraded_vnc else null end)
      }
    } | .passed = (.assertions | [.[] | select(. != null)] | all)'
}

# stop-during-recovery (cancel_resume): freeze x11vnc, and while the probe says degraded (recovery pending)
# run a manual `docker stop`: it must exit 0 promptly, must NOT be restarted by anyone, and a later start must work.
run_stop_case() {
  local name=stop started; started=$(now_utc)
  log "case $name: fresh volume, freeze x11vnc, docker stop while degraded, then start"
  if ! stack_fresh_ready; then case_error "$name" "precondition: $READY_REASON"; return 0; fi
  local cid=$CASE_CID
  wait_past_grace || { case_error "$name" "startup grace did not end"; return 0; }
  local survey0 pids0 vpid rc0 line
  survey0=$(proc_survey "$cid"); pids0=$(pidmap "$survey0")
  vpid=$(printf '%s' "$pids0" | jq -r '.x11vnc[0] // empty')
  [ -n "$vpid" ] || { case_error "$name" "no live x11vnc"; return 0; }
  line=$(container_inspect_line "$cid"); set -- $line; rc0=${2:-0}
  log "STOP -> x11vnc pid $vpid"
  qa_mutate timeout 20 docker exec "$cid" kill -STOP "$vpid" || { case_error "$name" "kill -STOP failed"; return 0; }
  local T0=$SECONDS saw=false s
  local samples="$WORK/samples.stop.jsonl"; : >"$samples"
  while :; do
    s=$(take_sample "$T0"); printf '%s\n' "$s" >>"$samples"
    if printf '%s' "$s" | jq -e '.probe.phase=="degraded" and .probe.layer=="vnc"' >/dev/null 2>&1; then saw=true; break; fi
    [ $((SECONDS - T0)) -ge 90 ] && break
    sleep 1
  done
  local stop_rc=0 stop_t0=$SECONDS stop_secs exit_code status rc_after stop_t_end
  log "docker stop -t 30 (manual stop during degraded/recovery-pending)"
  qa_mutate timeout 60 docker stop -t 30 "$cid" >/dev/null 2>&1 || stop_rc=$?
  stop_secs=$((SECONDS - stop_t0))
  exit_code=$(docker inspect "$cid" --format '{{.State.ExitCode}}' 2>/dev/null); status=$(docker inspect "$cid" --format '{{.State.Status}}' 2>/dev/null)
  # observation: nobody may restart it (restart policy honors manual stop; budget not consumed); bounded, time is the behavior
  local obs_end=$((SECONDS + 30)) stayed=true l o_st o_rc
  while [ "$SECONDS" -lt "$obs_end" ]; do
    l=$(container_inspect_line "$cid"); set -- $l; o_st=${1:-gone}; o_rc=${2:--1}
    { [ "$o_st" = exited ] && [ "$o_rc" = "$rc0" ]; } || stayed=false
    sleep "$POLL_INTERVAL"
  done
  rc_after=$o_rc
  local start_rc=0 resumed=false
  qa_mutate timeout 60 docker start "$cid" >/dev/null 2>&1 || start_rc=$?
  [ "$start_rc" = 0 ] && wait_runtime_ready && resumed=true
  local state logs cid1 rc1
  state=$(runtime_state_json); [ -n "$state" ] || state=null
  logs=$(runtime_log_lines); [ -n "$logs" ] || logs='[]'
  cid1=$(docker inspect "$QA_CONTAINER" --format '{{.Id}}' 2>/dev/null); rc1=$(docker inspect "$QA_CONTAINER" --format '{{.RestartCount}}' 2>/dev/null)
  jq -n -c --arg name "$name" --arg started "$started" --arg finished "$(now_utc)" --argjson saw "$saw" \
    --argjson stop_rc "$stop_rc" --argjson stop_secs "$stop_secs" --arg exit_code "$exit_code" --arg status "$status" \
    --argjson stayed "$stayed" --argjson rc0 "$rc0" --argjson rc_after "${rc_after:--1}" --argjson start_rc "$start_rc" --argjson resumed "$resumed" \
    --arg cid0 "$cid" --arg cid1 "$cid1" --arg rc1 "${rc1:--1}" --argjson state "$state" --argjson logs "$logs" \
    --slurpfile samples "$samples" --argjson src "$SRC_JSON" \
    '($state.budget_entries // []) as $bud
    | { case:$name, adversarial:"cancel_resume", started_at:$started, finished_at:$finished,
        source:$src, container:{id_before:$cid0, id_after:$cid1, restart_count_before:$rc0, restart_count_after_stop_observation:$rc_after, restart_count_after_start:($rc1|tonumber)},
        stop:{exit_status_of_docker_stop:$stop_rc, seconds:$stop_secs, container_exit_code:($exit_code|tonumber? // null), container_status:$status},
        runtime_state_after_start:$state, runtime_log_lines:$logs, samples:$samples,
        assertions:{
          degraded_vnc_observed_before_stop:$saw,
          docker_stop_succeeded:($stop_rc == 0),
          stop_within_grace_30s:($stop_secs < 30),
          clean_exit_code_0:($exit_code == "0"),
          stayed_exited_30s_no_restart_loop:$stayed,
          restart_count_unchanged_by_manual_stop:($rc_after == $rc0),
          manual_start_ok_and_ready:$resumed,
          container_id_unchanged:($cid0 == $cid1),
          manual_stop_logged_and_not_counted:(($logs | map(select(contains("event=manual_stop") and contains("counted=0"))) | length) >= 1),
          budget_not_consumed_by_stop:(($bud | length) <= 1)
        } } | .passed = (.assertions | all)'
}

############################ todo 2: healthy ############################

cmd_healthy() {
  need_tools; resolve_guard; use_candidate
  local started; started=$(now_utc)
  local pb wb; pb=$(prod_snapshot); wb=$(worktree_state)
  ensure_candidate
  SRC_JSON=$(source_light)
  log "healthy: fresh volume, candidate image $CANDIDATE_TAG"
  local reason=""
  if ! stack_fresh_ready; then reason="$READY_REASON"; fi
  local cid=${CASE_CID:-} probe http page rfb hstat hc_cfg win samples="$WORK/samples.healthy.jsonl" state logs
  local stable=true rc0 rc1 pids0 pids1 line s i
  : >"$samples"
  if [ -z "$reason" ]; then
    probe=$(probe_json)
    http=$(http_code "$HTTP_URL"); page=$(vnc_html_capture); rfb=$(rfb_json)
    wait_health 120 || true; hstat=$HEALTH_FINAL
    hc_cfg=$(docker inspect "$QA_CONTAINER" --format '{{json .Config.Healthcheck}}' 2>/dev/null)
    wait_window || true; win=$WINDOW_JSON
    pids0=$(pidmap "$(proc_survey "$cid")"); line=$(container_inspect_line "$cid"); set -- $line; rc0=${2:-0}
    # observation: the monitor must not act on a healthy system (time is the behavior: >=3 monitor ticks)
    local obs_end=$((SECONDS + HEALTHY_OBSERVE)) t0=$SECONDS
    while [ "$SECONDS" -lt "$obs_end" ]; do
      s=$(take_sample "$t0"); printf '%s\n' "$s" >>"$samples"
      sample_ready "$s" || stable=false
      sleep 5
    done
    pids1=$(pidmap "$(proc_survey "$cid")"); line=$(container_inspect_line "$cid"); set -- $line; rc1=${2:-0}
    state=$(runtime_state_json); [ -n "$state" ] || state=null
    logs=$(runtime_log_lines); [ -n "$logs" ] || logs='[]'
  fi
  local finished; finished=$(now_utc)
  local json
  if [ -n "$reason" ]; then
    json=$(jq -n -c --arg started "$started" --arg finished "$finished" --arg r "$reason" --argjson src "$SRC_JSON" \
      '{task:"task-2-healthy", schema:1, command:"bash scripts/qa-runtime.sh healthy", started_at:$started, finished_at:$finished, exit_code:2, passed:false, error:$r, source:$src}')
  else
    json=$(jq -n -c --arg started "$started" --arg finished "$finished" --argjson src "$SRC_JSON" --argjson ready_s "$READY_SECS" \
      --argjson probe "$probe" --arg http "$http" --argjson page "$page" --argjson rfb "$rfb" --arg hstat "$hstat" --argjson hc "${hc_cfg:-null}" \
      --argjson win "$win" --argjson stable "$stable" --argjson rc0 "$rc0" --argjson rc1 "$rc1" --argjson p0 "$pids0" --argjson p1 "$pids1" \
      --argjson state "$state" --argjson logs "$logs" --slurpfile samples "$samples" --arg ws "$WS_URL" \
      --arg cand_id "$(img_id "$CANDIDATE_TAG")" --arg base_id "$(img_id "$BASELINE_TAG")" --arg cont_img "$(docker inspect "$QA_CONTAINER" --format '{{.Image}}' 2>/dev/null)" \
      --argjson pb "$pb" --argjson pa "$(prod_snapshot)" --argjson wb "$wb" --argjson wa "$(worktree_state)" --argjson observe "$HEALTHY_OBSERVE" \
      'def nonready: (.probe.rc == 0 and .probe.phase == "ready" and .http_status == 200 and .rfb_ok == true) | not;
       ($samples | map(nonready)) as $nr
       | (reduce $nr[] as $b ({cur:0, max:0}; if $b then (.cur += 1 | .max = ([.max, .cur] | max)) else .cur = 0 end) | .max) as $maxrun
       | ($samples | map(select(nonready) | {t_s, probe_record:(.probe.record // null), phase:(.probe.phase // null), layer:(.probe.layer // null), reason:(.probe.reason // null), http_status, rfb_ok})) as $degraded
       | (($samples | length) > 0 and $maxrun < 3 and ($nr | last) == false) as $transient_only
       | ($state.budget_entries // []) as $bud
       | { task:"task-2-healthy", schema:1, command:"bash scripts/qa-runtime.sh healthy", started_at:$started, finished_at:$finished,
           source:$src, images:{baseline_tag_id:$base_id, candidate_tag_id:$cand_id, container_image_id:$cont_img},
           seconds_to_ready:$ready_s,
           probe:$probe, http:{status:($http|tonumber? // 0), vnc_html:$page}, websocket_rfb:($rfb + {url:$ws}),
           docker_health:{status:$hstat, healthcheck_config:$hc},
           kakaotalk_window:$win,
           observation:{window_s:$observe, samples:$samples, all_samples_ready:$stable,
                        degraded_samples:{count:($degraded | length), total_samples:($samples | length), max_consecutive:$maxrun, monitor_failure_threshold:3, samples:$degraded,
                          policy:"an isolated transient probe miss is tolerated (the monitor itself needs 3 consecutive failures); it still fails on a non-ready last sample, a run of 3+ non-ready samples, any restart, PID change or budget entry"},
                        restart_count_before:$rc0, restart_count_after:$rc1, pids_before:$p0, pids_after:$p1},
           runtime_state:$state, runtime_log_lines:$logs,
           production:{before:$pb, after:$pa, unchanged:(($pb.found // false) and ($pa.found // false) and $pb.id == $pa.id and $pb.started_at == $pa.started_at and $pb.restart_count == $pa.restart_count and $pb.status == $pa.status)},
           worktree:{unchanged_excluding_evidence:($wb.status_sha256 == $wa.status_sha256 and $wb.diff_binary_sha256 == $wa.diff_binary_sha256)},
           adversarial:{
             misleading_success_output:{probed:true, finding:"ready requires the in-container probe (RFB banner on 5900) AND an independent ws://127.0.0.1:24500/websockify RFB handshake from the host; HTTP 200 alone is never accepted"},
             stale_state:{probed:true, finding:"prep_fresh removes any QA-owned container/volume first, so the run starts on a fresh QA volume"},
             hung_commands:{probed:true, finding:"every docker exec/curl/python call is wrapped in timeout; all waits have deadlines"},
             flaky_tests:{probed:true, finding:"no fixed sleeps as synchronization; state predicates with deadlines; the 45s observation is time-as-behavior (monitor ticks)"}},
           assertions:{
             probe_record_ready_exit0:($probe.rc == 0 and $probe.phase == "ready"),
             http_200:(($http|tonumber? // 0) == 200),
             websocket_rfb_handshake_ok:($rfb.ok == true and ($rfb.banner // "" | startswith("RFB 003."))),
             docker_health_healthy:($hstat == "healthy"),
             image_declares_healthcheck:($hc != null and ($hc.Test // []) != []),
             kakaotalk_window_present:($win.kakaotalk_class_windows > 0),
             kakaotalk_login_ui_not_error_dialog:(($win.login_ui_present // false) == true),
             no_false_positive_actions:($transient_only and $rc0 == $rc1 and (($p0.xvfb + $p0.x11vnc + $p0.websockify + $p0.openbox) == ($p1.xvfb + $p1.x11vnc + $p1.websockify + $p1.openbox)) and ($bud | length) == 0),
             wine_initialized_marker_present:($state.wine_initialized_marker == "present"),
             container_runs_candidate_image:($cont_img == $cand_id)
           } } | .passed = (.assertions | all) | .exit_code = (if .passed then 0 else 2 end)')
  fi
  write_evidence task-2-healthy.json "$json"
  printf '%s\n' "$json" | jq '{passed, assertions, seconds_to_ready}'
  [ "$(printf '%s' "$json" | jq -r '.passed')" = true ] || exit "$EX_ENV"
}

############################ todo 2: recovery ############################

cmd_recovery() {
  need_tools; resolve_guard; use_candidate
  local cases=("$@") c
  [ "${#cases[@]}" -gt 0 ] || read -r -a cases <<<"$RECOVERY_CASES"
  for c in "${cases[@]}"; do
    case " $RECOVERY_CASES " in *" $c "*) ;; *) log "unknown recovery case '$c' (valid: $RECOVERY_CASES)"; exit "$EX_USAGE" ;; esac
  done
  local started; started=$(now_utc)
  local pb wb; pb=$(prod_snapshot); wb=$(worktree_state)
  ensure_candidate
  SRC_JSON=$(source_light)
  local fb fc cmp
  fb=$(image_facts_for "$BASELINE_TAG"); fc=$(image_facts_for "$CANDIDATE_TAG")
  [ -n "$fb" ] && [ -n "$fc" ] || die_env "could not collect image facts"
  cmp=$(facts_compare "$fb" "$fc")
  local results="$WORK/cases.jsonl" rc f; : >"$results"
  for c in "${cases[@]}"; do
    f="$WORK/case.$c.json"; rm -f "$f"
    if [ "$c" = stop ]; then ( run_stop_case ) >"$f"; rc=$?; else ( run_fault_case "$c" ) >"$f"; rc=$?; fi
    if ! jq -e . "$f" >/dev/null 2>&1; then case_error "$c" "case aborted without result (subshell exit $rc)" >"$f"; fi
    jq -c . "$f" >>"$results"
    log "case $c: passed=$(jq -r '.passed' "$f")"
  done
  local pa wa json
  pa=$(prod_snapshot); wa=$(worktree_state)
  json=$(jq -s -c --arg started "$started" --arg finished "$(now_utc)" --argjson src "$SRC_JSON" --argjson fb "$fb" --argjson fc "$fc" --argjson cmp "$cmp" \
    --argjson pb "$pb" --argjson pa "$pa" --argjson wb "$wb" --argjson wa "$wa" --argjson deadline "$RECOVERY_DEADLINE" \
    --arg cand_id "$(img_id "$CANDIDATE_TAG")" --arg base_id "$(img_id "$BASELINE_TAG")" '
    { task:"task-2-recovery", schema:1, command:"bash scripts/qa-runtime.sh recovery", started_at:$started, finished_at:$finished,
      source:$src, images:{baseline_tag_id:$base_id, candidate_tag_id:$cand_id},
      image_facts:{baseline:$fb, candidate:$fc, comparison:$cmp},
      cases:., 
      result:{cases_total:length, cases_passed:(map(select(.passed == true)) | length), deadline_s:$deadline,
              passed:(all(.[]; .passed == true)), note:"each case ran on a fresh QA volume; fault = signal to the exact QA PID; recovery measured from injection to probe ready + WS RFB banner"},
      production:{before:$pb, after:$pa, unchanged:(($pb.found // false) and ($pa.found // false) and $pb.id == $pa.id and $pb.started_at == $pa.started_at and $pb.restart_count == $pa.restart_count and $pb.status == $pa.status)},
      worktree:{before:$wb, after:$wa, unchanged_excluding_evidence:($wb.status_sha256 == $wa.status_sha256 and $wb.diff_binary_sha256 == $wa.diff_binary_sha256)},
      bounds:{recovery_deadline_s:$deadline, fixed_sleep_synchronization:false,
              note:"waits are deadline-bounded predicate polls; startup grace/observation windows are time-as-behavior"},
      adversarial:{
        misleading_success_output:{probed:true, finding:"samples record HTTP 200 next to a failing probe/RFB while a layer is down (freeze case); recovery requires probe ready AND independent WS RFB banner"},
        stale_state:{probed:true, finding:"fresh QA volume and container per case (prep_fresh down -v before every case)"},
        hung_commands:{probed:true, finding:"every docker/curl/python call is bounded by timeout; the freeze case proves a SIGSTOPped x11vnc cannot hang the probe or the monitor"},
        flaky_tests:{probed:true, finding:"no fixed sleeps as synchronization; each case is a single run with deadline polling; recovery times are recorded, not assumed"},
        cancel_resume:{probed:true, finding:"case stop: docker stop while degraded exits 0 inside the 30s grace, is not restarted, does not consume budget, and a later start recovers"},
        dirty_worktree:{probed:true, finding:"source revision + tracked diff hash + untracked-files hash recorded per run; candidate image script hashes verified equal to the worktree"},
        production_interference:{probed:true, finding:"production only inspected; before/after snapshot compared (production.unchanged)"},
        secrets_leak:{probed:true, finding:"N/A: QA uses an empty VNC_PASSWORD and no account; records contain phase/layer/reason/time/counts and class names only"},
        data_loss:{probed:true, finding:"N/A: only the QA-only volume is created/removed; no wineserver -k in normal recovery"},
        network_exposure:{probed:true, finding:"QA ports bound to 127.0.0.1 only (guard-enforced)"}}}' "$results") || die_env "failed to assemble recovery JSON"
  json=$(printf '%s' "$json" | jq -c '.exit_code = (if .result.passed then 0 else 2 end)')
  local out=task-2-recovery.json
  if [ "$#" -gt 0 ]; then # subset run: never overwrite the full-run evidence
    out="task-2-recovery-$(IFS=-; printf '%s' "${cases[*]}")-repeat.json"
    json=$(printf '%s' "$json" | jq -c --arg c "${cases[*]}" '.task="task-2-recovery-repeat" | .command=("bash scripts/qa-runtime.sh recovery " + $c) | .subset_run=true')
  fi
  write_evidence "$out" "$json"
  printf '%s\n' "$json" | jq '{result, cases:[.cases[] | {case, passed, seconds:(.assertions.seconds_from_injection_to_ready_and_rfb // null), assertions}]}'
  [ "$(printf '%s' "$json" | jq -r '.result.passed')" = true ] || exit "$EX_ENV"
}

############################ todo 2 part B: shared helpers ############################

# Entrypoint defaults (asserted per case: the container carries no non-empty KAKAO_* override).
NF_MONITOR_INTERVAL=10
NF_FAIL_THRESHOLD=3
NF_STARTUP_GRACE=90
NF_FAILURE_WINDOW=$((NF_MONITOR_INTERVAL * NF_FAIL_THRESHOLD))
NF_MIN_OBSERVE=$((3 * NF_MONITOR_INTERVAL + NF_FAILURE_WINDOW))      # 3 monitor intervals + 1 failure window = 60s
NF_IDLE_MIN=$((NF_STARTUP_GRACE + 3 * NF_MONITOR_INTERVAL))          # startup grace + 3 intervals = 120s
NF_OBSERVE="${QA_NONFAULT_OBSERVE:-75}"
NF_IDLE="${QA_LOGIN_IDLE:-130}"
CIRCUIT_OBSERVE="${QA_CIRCUIT_OBSERVE:-90}"
INIT_BLOCK_DEADLINE="${QA_INIT_BLOCK_DEADLINE:-420}"
INIT_OBSERVE="${QA_INIT_OBSERVE:-60}"
INIT_WINEBOOT_TIMEOUT=0.2   # fractional `timeout`: wineboot can never finish, so run_bg returns 124 deterministically
MUTANT_TAG=kakaotalk-wine:reliability-mutant
# Production was restarted by the host/docker daemon (all containers, 2026-10-15T04:12:03Z), not by QA; the value below is the
# pre-restart baseline from the plan, QA_PROD_EXPECT_STARTED_AT supplies the observed post-restart value (unchanged-during-run is still asserted).
PROD_EXPECT_STARTED_AT="${QA_PROD_EXPECT_STARTED_AT:-2026-10-14T23:41:51.739301308Z}"

log_action_count() { # automatic-action records (relaunch / full exit / boot exit) in the container stdout
  local n; n=$(timeout 30 docker logs "$QA_CONTAINER" 2>&1 | grep -a '\[kakao-runtime\]' | grep -a -c -E 'action=(relaunch_|full_cleanup_exit|exit)|event=app_relaunch') || true
  printf '%s' "${n:-0}"
}

runtime_total_lines() { # total [kakao-runtime] lines (spam / loop detector)
  local n; n=$(timeout 30 docker logs "$QA_CONTAINER" 2>&1 | grep -a -c '\[kakao-runtime\]') || true
  printf '%s' "${n:-0}"
}

kakao_env_overrides() { # non-empty KAKAO_* tunables set on the QA container
  docker inspect "$QA_CONTAINER" --format '{{json .Config.Env}}' 2>/dev/null | jq -c '[.[] | select(startswith("KAKAO_") and (test("=$") | not))]'
}

pids_dead() { # <cid> <pids-json>: 0 when none of the PIDs is alive (zombies do not count)
  proc_survey "$1" | jq -e --argjson p "$2" '[.[] | select(.state != "Z" and .state != "X" and (.pid as $x | $p | index($x) != null))] | length == 0' >/dev/null 2>&1
}

OBS_ALL_READY=true; OBS_SECS=0
observe_window() { # <seconds> <samples-file>: bounded sampling; waiting for time itself is the behavior under test
  local secs=$1 f=$2 t0=$SECONDS end s
  end=$((SECONDS + secs)); OBS_ALL_READY=true
  while :; do
    s=$(take_sample "$t0"); printf '%s\n' "$s" >>"$f"
    sample_ready "$s" || OBS_ALL_READY=false
    [ "$SECONDS" -ge "$end" ] && break
    sleep 5
  done
  OBS_SECS=$((SECONDS - t0))
}

# emit_receipt <task> <command> <out-file> <results.jsonl> <extra-json>; needs R_STARTED R_PB R_WB SRC_JSON
emit_receipt() {
  local task=$1 cmdline=$2 out=$3 results=$4 extra=$5 pa wa json
  pa=$(prod_snapshot); wa=$(worktree_state)
  json=$(jq -s -c --arg task "$task" --arg cmd "$cmdline" --arg started "$R_STARTED" --arg finished "$(now_utc)" --argjson src "$SRC_JSON" \
    --argjson pb "$R_PB" --argjson pa "$pa" --argjson wb "$R_WB" --argjson wa "$wa" --argjson extra "$extra" \
    --arg exp_started "$PROD_EXPECT_STARTED_AT" --arg cand_id "$(img_id "$CANDIDATE_TAG")" --arg base_id "$(img_id "$BASELINE_TAG")" '
    { task:$task, schema:1, command:$cmd, started_at:$started, finished_at:$finished, source:$src,
      images:{baseline_tag_id:$base_id, candidate_tag_id:$cand_id},
      cases:.,
      result:{cases_total:length, cases_passed:(map(select(.passed == true)) | length), passed:(all(.[]; .passed == true))},
      production:{before:$pb, after:$pa,
                  unchanged:(($pb.found // false) and ($pa.found // false) and $pb.id == $pa.id and $pb.started_at == $pa.started_at and $pb.restart_count == $pa.restart_count and $pb.status == $pa.status),
                  matches_expected_started_at_and_zero_restarts:($pa.started_at == $exp_started and $pa.restart_count == 0)},
      worktree:{before:$wb, after:$wa, unchanged_excluding_evidence:($wb.status_sha256 == $wa.status_sha256 and $wb.diff_binary_sha256 == $wa.diff_binary_sha256)} }
    * $extra
    | .result.passed = (.result.passed and .production.unchanged and .production.matches_expected_started_at_and_zero_restarts)
    | .exit_code = (if .result.passed then 0 else 2 end)' "$results") || die_env "failed to assemble $task JSON"
  write_evidence "$out" "$json"
  printf '%s\n' "$json" | jq '{task, result, production:{unchanged:.production.unchanged, matches_expected:.production.matches_expected_started_at_and_zero_restarts}, cases:[.cases[] | {case, passed, assertions}]}'
  [ "$(printf '%s' "$json" | jq -r '.result.passed')" = true ] || exit "$EX_ENV"
}

ADVERSARIAL_COMMON='{
  "flaky_tests":{"probed":true, "finding":"no fixed sleeps as synchronization: every wait is a deadline-bounded state predicate; the observation windows are time-as-behavior and the asserted minimum is checked against the measured elapsed seconds"},
  "hung_commands":{"probed":true, "finding":"every docker exec/logs/events/curl/python call is wrapped in timeout; all loops carry a deadline"},
  "stale_state":{"probed":true, "finding":"prep_fresh removes any QA-owned container/volume first: every scenario starts on a fresh QA volume (and fresh runtime-state/budget)"},
  "misleading_success_output":{"probed":true, "finding":"a pass needs probe ready AND HTTP 200 AND an independent WebSocket RFB banner in EVERY sample, plus pid-set equality and the monitor own recovery_count/budget; a quiet log alone is never accepted"}
}'

############################ todo 2 part B: nonfaults ############################

kill_launcher_chain() { # SIGKILL the runner chain of the supervisor (dbus-run-session, dbus-daemon, run-kakao bash); never KakaoTalk.exe nor its wine parent start.exe (killing start.exe takes the app down: verified)
  qa_mutate timeout 30 docker exec "$QA_CONTAINER" sh -c '
    L=$(grep -m1 "^launcher_pid=" /data/runtime-state/state | cut -d= -f2)
    [ -n "$L" ] || exit 1
    all="$L"
    for k in $(pgrep -P "$L"); do all="$all $k $(pgrep -P "$k")"; done
    out=""
    for p in $all; do
      c=$(cat /proc/$p/comm 2>/dev/null) || continue
      [ "$c" = KakaoTalk.exe ] && continue
      [ "$c" = start.exe ] && continue
      out="$out $p:$c"
      kill -KILL "$p" 2>/dev/null
    done
    echo "$out"' 2>/dev/null
}

win_probe() { # <window-id> -> "<MapState> <visible-class-matches> <wmctrl-kakaotalk-windows>" (counts only, no titles)
  timeout 20 docker exec "$QA_CONTAINER" sh -c '
    echo "$(xwininfo -id "$1" 2>/dev/null | awk "/Map State/ {print \$3}") $(xdotool search --onlyvisible --class "kakaotalk\.exe" 2>/dev/null | wc -l | tr -d " ") $(wmctrl -lx 2>/dev/null | grep -ci "kakaotalk\.exe")"' _ "$1" 2>/dev/null
}

win_action() { # <min|unmap|restore> <window-id>
  case "$1" in
    min) qa_mutate timeout 20 docker exec "$QA_CONTAINER" xdotool windowminimize "$2" ;;
    unmap) qa_mutate timeout 20 docker exec "$QA_CONTAINER" xdotool windowunmap "$2" ;;
    restore) qa_mutate timeout 20 docker exec "$QA_CONTAINER" sh -c 'xdotool windowmap "$1"; xdotool windowactivate "$1"' _ "$2" ;;
  esac
}

NF_CID=""; NF_WIN0=null; NF_PIDS0=null; NF_RC0=0; NF_STARTED0=""; NF_STATE0=null; NF_ACT0=0; NF_PRE=null; NF_WID=""; NF_VIS0=1
nf_prepare() { # <skip-grace-wait 0|1>: fresh stack, steady login screen, pre-state; READY_REASON on failure
  stack_fresh_ready || return 1
  NF_CID=$CASE_CID
  if [ "$1" != 1 ]; then wait_past_grace || { READY_REASON="startup grace did not end"; return 1; }; fi
  wait_window || { READY_REASON="no KakaoTalk top-level window"; return 1; }
  NF_WIN0=$WINDOW_JSON
  NF_PIDS0=$(pidmap "$(proc_survey "$NF_CID")")
  local line; line=$(container_inspect_line "$NF_CID"); set -- $line; NF_RC0=${2:-0}; NF_STARTED0=${3:-}
  NF_STATE0=$(runtime_state_json); [ -n "$NF_STATE0" ] || NF_STATE0=null
  NF_ACT0=$(log_action_count)
  # the login window (smallest login-sized kakaotalk.exe window): the app also owns a slightly larger, always-visible shadow window
  # (392x642 around the 390x640 login window), so "hidden" means: this window unmapped AND the visible class-match count dropped
  NF_WID=$(timeout 20 docker exec "$NF_CID" sh -c 'wmctrl -lxG 2>/dev/null | awk -v mw="$1" -v mh="$2" "\$7 ~ /kakaotalk/ && \$5 >= mw && \$6 >= mh {print \$5*\$6, \$1}" | sort -n | head -n 1 | cut -d" " -f2' _ "$UI_MIN_W" "$UI_MIN_H" 2>/dev/null | tr -d ' \r\n')
  [ -n "$NF_WID" ] || { READY_REASON="no login-sized KakaoTalk window id"; return 1; }
  set -- $(win_probe "$NF_WID"); NF_VIS0=${2:-1}
  NF_PRE=$(take_sample "$SECONDS")
  sample_ready "$NF_PRE" || { READY_REASON="not ready before the non-fault action"; return 1; }
  [ "$(printf '%s' "$NF_PIDS0" | jq '.app | length')" -ge 1 ] || { READY_REASON="no KakaoTalk.exe process before the non-fault action"; return 1; }
}

# nf_assemble <name> <phases-json> <checks-json> <min-observe-s> <started>: case JSON on stdout
nf_assemble() {
  local name=$1 phases=$2 checks=$3 minobs=$4 started=$5 samples="$WORK/samples.nf.$1.jsonl"
  local pids1 line1 rc1 started1 cid1 state1 act1 logs health envs win1
  pids1=$(pidmap "$(proc_survey "$NF_CID")")
  wait_health 60 || true; health=$HEALTH_FINAL
  line1=$(container_inspect_line "$QA_CONTAINER"); set -- $line1; rc1=${2:--1}; started1=${3:-}
  cid1=$(docker inspect "$QA_CONTAINER" --format '{{.Id}}' 2>/dev/null)
  state1=$(runtime_state_json); [ -n "$state1" ] || state1=null
  act1=$(log_action_count); logs=$(runtime_log_lines); [ -n "$logs" ] || logs='[]'
  envs=$(kakao_env_overrides); [ -n "$envs" ] || envs='["unreadable"]'
  win1=$(kakao_windows); [ -n "$win1" ] || win1=null
  jq -n -c --arg name "$name" --arg started "$started" --arg finished "$(now_utc)" --argjson phases "$phases" --argjson checks "$checks" \
    --argjson minobs "$minobs" --argjson pids0 "$NF_PIDS0" --argjson pids1 "$pids1" --argjson rc0 "${NF_RC0:-0}" --argjson rc1 "${rc1:--1}" \
    --arg cid0 "$NF_CID" --arg cid1 "$cid1" --arg started0 "$NF_STARTED0" --arg started1 "$started1" --arg health "$health" \
    --argjson envs "$envs" --argjson state0 "$NF_STATE0" --argjson state1 "$state1" --argjson act0 "${NF_ACT0:-0}" --argjson act1 "${act1:-0}" \
    --argjson logs "$logs" --argjson win0 "$NF_WIN0" --argjson win1 "$win1" --argjson pre "$NF_PRE" --slurpfile samples "$samples" \
    --argjson interval "$NF_MONITOR_INTERVAL" --argjson thr "$NF_FAIL_THRESHOLD" --argjson fwin "$NF_FAILURE_WINDOW" --argjson grace "$NF_STARTUP_GRACE" '
    def keys_cmp: ["xvfb","openbox","x11vnc","websockify","app","entrypoint"];
    def nonready: (.probe.rc == 0 and .probe.phase == "ready" and .http_status == 200 and .rfb_ok == true) | not;
    ($samples | map(nonready)) as $nr
    | (reduce $nr[] as $b ({cur:0, max:0}; if $b then (.cur += 1 | .max = ([.max, .cur] | max)) else .cur = 0 end) | .max) as $maxrun
    | ($samples | map(select(nonready) | {t_s, probe_record:(.probe.record // null), phase:(.probe.phase // null), layer:(.probe.layer // null), reason:(.probe.reason // null), http_status, rfb_ok})) as $degraded
    | ($state0.state // {}) as $s0 | ($state1.state // {}) as $s1
    | { case:$name, started_at:$started, finished_at:$finished,
        monitor:{interval_s:$interval, fail_threshold:$thr, failure_window_s:$fwin, startup_grace_s:$grace, min_observe_s:$minobs},
        phases:$phases,
        container:{id_before:$cid0, id_after:$cid1, restart_count_before:$rc0, restart_count_after:$rc1, started_at_before:$started0, started_at_after:$started1},
        pids_before:$pids0, pids_after:$pids1, pre_sample:$pre, kakaotalk_window_before:$win0, kakaotalk_window_after:$win1,
        docker_health_after:$health, kakao_env_overrides:$envs,
        runtime_state_before:$state0, runtime_state_after:$state1, runtime_log_lines:$logs,
        automatic_action_records:{before:$act0, after:$act1},
        degraded_samples:{count:($degraded | length), total_samples:($samples | length), max_consecutive:$maxrun, monitor_failure_threshold:$thr, samples:$degraded,
          policy:"a single transient probe miss is tolerated (the monitor itself needs consecutive failures); the case still fails on any PID change, relaunch/exit record, budget entry, recovery_count change, RestartCount change, a non-ready final sample or a run of non-ready samples reaching the monitor threshold"},
        samples:$samples,
        assertions: ({
          samples_ready_except_isolated_transient_misses: (($samples | length) > 0 and $maxrun < $thr and ($nr | last) == false),
          pids_unchanged_in_every_sample: ($samples | all(.[]; . as $s | keys_cmp | all(. as $k | (($s.pids[$k] // []) | sort) == (($pids0[$k] // []) | sort)))),
          pids_unchanged_after: (keys_cmp | all(. as $k | (($pids1[$k] // []) | sort) == (($pids0[$k] // []) | sort))),
          zero_automatic_relaunches_or_exits: ($act0 == 0 and $act1 == 0),
          recovery_count_unchanged_zero: ($s0.recovery_count == "0" and $s1.recovery_count == "0"),
          budget_entries_unchanged_and_empty: (($state0.budget_entries // ["?"]) == [] and ($state1.budget_entries // ["?"]) == []),
          not_blocked_and_ready_after: ($s1.blocked == "0" and $s1.phase == "ready"),
          docker_restart_count_unchanged: ($rc0 == $rc1),
          container_id_and_started_at_unchanged: ($cid0 == $cid1 and $started0 == $started1),
          observed_at_least_required_seconds_per_phase: ($phases | all(.[]; .observed_s >= $minobs)),
          docker_health_healthy_after: ($health == "healthy"),
          kakaotalk_window_present_at_end: (($win1.kakaotalk_class_windows // 0) > 0),
          kakaotalk_login_ui_not_error_dialog_at_end: (($win1.login_ui_present // false) == true),
          no_kakao_env_overrides: ($envs == [])
        } + $checks) }
    | .passed = (.assertions | all)'
}

run_nonfault_case() { # <a|b|c>: prints the case JSON (runs in a subshell)
  local id=$1 name started samples
  case "$id" in
    a) name=launcher_exit_app_alive ;;
    b) name=window_minimized_or_hidden ;;
    c) name=login_wait_idle ;;
    *) case_error "$id" "unknown nonfault case"; return 0 ;;
  esac
  started=$(now_utc); samples="$WORK/samples.nf.$name.jsonl"; : >"$samples"
  log "nonfault $id ($name): fresh volume, candidate image"
  local skip=0; [ "$id" = c ] && skip=1
  nf_prepare "$skip" || { case_error "$name" "precondition: $READY_REASON"; return 0; }
  local phases checks
  case "$id" in
    a)
      local killed kp kc gone=false dl lpid
      killed=$(kill_launcher_chain) || { case_error "$name" "could not kill the runner chain"; return 0; }
      kp=$(printf '%s\n' "$killed" | tr ' ' '\n' | awk -F: 'NF == 2 {print $1}' | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber)')
      kc=$(printf '%s\n' "$killed" | tr ' ' '\n' | awk -F: 'NF == 2 {print $2}' | jq -R -s -c 'split("\n") | map(select(length > 0))')
      lpid=$(printf '%s' "$NF_STATE0" | jq -r '.state.launcher_pid // empty')
      log "runner chain killed (pids $kp comms $kc); KakaoTalk.exe left alive"
      dl=$((SECONDS + 20))
      until pids_dead "$NF_CID" "$kp" || [ "$SECONDS" -ge "$dl" ]; do sleep 1; done
      pids_dead "$NF_CID" "$kp" && gone=true
      observe_window "$NF_OBSERVE" "$samples"
      phases=$(jq -n -c --argjson kp "$kp" --argjson kc "$kc" --argjson gone "$gone" --argjson s "$OBS_SECS" \
        '[{name:"launcher_runner_exited_while_app_alive", action:{signal:"KILL", killed_pids:$kp, killed_comms:$kc, all_gone:$gone}, observed_s:$s}]')
      checks=$(jq -n -c --argjson kp "$kp" --argjson gone "$gone" --arg lpid "${lpid:-0}" --argjson p0 "$NF_PIDS0" \
        '{launcher_pid_killed:(($kp | index(($lpid | tonumber))) != null), killed_runner_pids_gone:$gone, app_pid_untouched_by_injection:((($kp | length) > 0) and (($kp - ($p0.app)) | length) == ($kp | length))}')
      ;;
    b)
      local mode mname hid still back ws dl2 obs_s ph='[]' restored_all=true
      for mode in min unmap; do
        [ "$mode" = min ] && mname=windowminimize || mname=windowunmap
        win_action "$mode" "$NF_WID" || { case_error "$name" "$mname failed"; return 0; }
        hid=false; dl2=$((SECONDS + 15))
        while :; do
          ws=$(win_probe "$NF_WID"); set -- $ws
          if [ "${1:-}" = IsUnMapped ] && [ "${2:-$NF_VIS0}" -lt "$NF_VIS0" ] 2>/dev/null; then hid=true; break; fi
          [ "$SECONDS" -ge "$dl2" ] && break
          sleep 1
        done
        observe_window "$NF_OBSERVE" "$samples"; obs_s=$OBS_SECS
        ws=$(win_probe "$NF_WID"); set -- $ws
        still=false; [ "${1:-}" = IsUnMapped ] && [ "${2:-$NF_VIS0}" -lt "$NF_VIS0" ] 2>/dev/null && still=true
        win_action restore "$NF_WID" || true
        back=false; dl2=$((SECONDS + 15))
        while :; do
          ws=$(win_probe "$NF_WID"); set -- $ws
          if [ "${1:-}" = IsViewable ] && [ "${2:-0}" -ge "$NF_VIS0" ] 2>/dev/null; then back=true; break; fi
          [ "$SECONDS" -ge "$dl2" ] && break
          sleep 1
        done
        [ "$back" = true ] || restored_all=false
        ph=$(printf '%s' "$ph" | jq -c --arg m "$mname" --argjson hid "$hid" --argjson still "$still" --argjson back "$back" --argjson s "$obs_s" --arg wid "$NF_WID" \
          '. + [{name:("xdotool " + $m), action:{xdotool:$m, window_class:"kakaotalk.exe.kakaotalk.exe", window_id:$wid}, hidden_confirmed_after_action:$hid, still_hidden_at_end_of_observation:$still, restored_after_observation:$back, observed_s:$s}]')
        log "nonfault b: $mname hidden=$hid still_hidden=$still restored=$back observed=${obs_s}s"
      done
      phases=$ph
      checks=$(printf '%s' "$ph" | jq -c '{window_hidden_confirmed_for_both_actions:(all(.[]; .hidden_confirmed_after_action)), window_stayed_hidden_for_whole_observation:(all(.[]; .still_hidden_at_end_of_observation)), window_restorable_after_each:(all(.[]; .restored_after_observation))}')
      ;;
    c)
      local tend gu
      observe_window "$NF_IDLE" "$samples"
      tend=$(timeout 20 docker exec "$NF_CID" date +%s 2>/dev/null | tr -d '\r\n')
      gu=$(printf '%s' "$NF_STATE0" | jq -r '.state.grace_until // 0')
      phases=$(jq -n -c --argjson s "$OBS_SECS" --argjson tend "${tend:-0}" --argjson gu "$gu" \
        '[{name:"login_screen_idle_no_input", action:{input:"none", account:"none (login screen)"}, observed_s:$s, grace_until_epoch:$gu, ended_at_epoch:$tend}]')
      checks=$(jq -n -c --argjson tend "${tend:-0}" --argjson gu "$gu" --argjson iv "$NF_MONITOR_INTERVAL" \
        '{idle_covered_startup_grace_plus_3_intervals:(($tend - $gu) >= (3 * $iv))}')
      ;;
  esac
  local minobs=$NF_MIN_OBSERVE; [ "$id" = c ] && minobs=$NF_IDLE_MIN
  nf_assemble "$name" "$phases" "$checks" "$minobs" "$started"
}

cmd_nonfaults() { # [a|b|c ...]
  need_tools; resolve_guard; use_candidate
  local cases=("$@") c
  [ "${#cases[@]}" -gt 0 ] || cases=(a b c)
  for c in "${cases[@]}"; do case "$c" in a|b|c) ;; *) log "unknown nonfault case '$c' (valid: a b c)"; exit "$EX_USAGE" ;; esac; done
  R_STARTED=$(now_utc); R_PB=$(prod_snapshot); R_WB=$(worktree_state)
  ensure_candidate
  SRC_JSON=$(source_light)
  local results="$WORK/nf.cases.jsonl" f rc; : >"$results"
  for c in "${cases[@]}"; do
    f="$WORK/nf.case.$c.json"; rm -f "$f"
    ( run_nonfault_case "$c" ) >"$f"; rc=$?
    if ! jq -e . "$f" >/dev/null 2>&1; then case_error "nonfault-$c" "case aborted without result (subshell exit $rc)" >"$f"; fi
    jq -c . "$f" >>"$results"
    log "nonfault $c: passed=$(jq -r '.passed' "$f")"
  done
  local out=task-2-nonfaults.json extra
  [ "$#" -gt 0 ] && out="task-2-nonfaults-$(IFS=-; printf '%s' "${cases[*]}")-repeat.json"
  extra=$(jq -n -c --argjson adv "$ADVERSARIAL_COMMON" --argjson min "$NF_MIN_OBSERVE" --argjson idle "$NF_IDLE_MIN" --argjson subset "$([ "$#" -gt 0 ] && echo true || echo false)" \
    '{subset_run:$subset, requirements:{launcher_exit_min_observe_s:$min, window_hidden_min_observe_s_per_action:$min, login_idle_min_s:$idle,
        note:"launcher/runner exit and window hide use 3 monitor intervals + 1 failure window (3 x 10s); login idle uses startup grace 90s + 3 intervals; each scenario ran on a fresh QA volume"},
      adversarial:$adv}')
  emit_receipt task-2-nonfaults "bash scripts/qa-runtime.sh nonfaults${*:+ $*}" "$out" "$results" "$extra"
}

############################ todo 2 part B: circuit ############################

# (a) fake-clock unit run of the REAL budget functions: this script is piped into a throwaway, network-less
# container of the candidate image and SOURCES /usr/local/bin/kakao-entrypoint (the file embedded from docker/entrypoint.sh).
circuit_unit_script() {
  cat <<'EOS'
export KAKAO_STATE_DIR=$(mktemp -d)
. /usr/local/bin/kakao-entrypoint
T0=1800000000
ck() { local n=$1 ok=$2; shift 2; printf 'CHECK\t%s\t%s\t%s\n' "$n" "$ok" "$*"; }
yn() { if "$@"; then echo 1; else echo 0; fi; }
fresh() { rm -f "$KAKAO_STATE_DIR"/budget.log "$KAKAO_STATE_DIR"/last-failure.log "$KAKAO_STATE_DIR"/manual-recovery "$KAKAO_STATE_DIR"/image_id; READY_SINCE=0; BLOCKED=0; LAST_RESET=""; }
printf 'SHA\t%s\n' "$(sha256sum /usr/local/bin/kakao-entrypoint | cut -d' ' -f1)"
printf 'CFG\tmax=%s window_s=%s ready_reset_s=%s\n' "$BUDGET_MAX" "$BUDGET_WINDOW" "$READY_RESET_SECS"

# 1+2: three automatic actions allowed, the fourth denied and nothing recorded
fresh; KAKAO_FAKE_NOW=$T0
budget_consume relaunch r1; r1=$?
KAKAO_FAKE_NOW=$((T0+10)); budget_consume relaunch r2; r2=$?
KAKAO_FAKE_NOW=$((T0+20)); budget_consume full_exit r3; r3=$?
ck three_allowed "$([ "$r1$r2$r3" = 000 ] && [ "$(budget_count)" = 3 ] && echo 1 || echo 0)" "rc=$r1,$r2,$r3 count=$(budget_count) max=$BUDGET_MAX"
KAKAO_FAKE_NOW=$((T0+30)); h0=$(sha256sum <"$(BUDGET_FILE)")
budget_consume relaunch r4; r4=$?
h1=$(sha256sum <"$(BUDGET_FILE)")
ck fourth_denied "$([ "$r4" = 1 ] && [ "$(budget_count)" = 3 ] && [ "$(yn budget_exhausted)" = 1 ] && [ "$h0" = "$h1" ] && echo 1 || echo 0)" "rc=$r4 count=$(budget_count) file_unchanged=$([ "$h0" = "$h1" ] && echo yes || echo no)"

# 3: expiry after the 10 min window (entries at T0, T0+10, T0+20; an entry counts while ts > now-600)
KAKAO_FAKE_NOW=$((T0+599)); c599=$(budget_count); budget_consume relaunch r5; d599=$?
KAKAO_FAKE_NOW=$((T0+600)); c600=$(budget_count); budget_consume relaunch r6; a600=$?
c600b=$(budget_count)
KAKAO_FAKE_NOW=$((T0+601)); budget_consume relaunch r7; d601=$?
ck expiry_after_10_min "$([ "$c599" = 3 ] && [ "$d599" = 1 ] && [ "$c600" = 2 ] && [ "$a600" = 0 ] && [ "$c600b" = 3 ] && [ "$d601" = 1 ] && echo 1 || echo 0)" "t+599: count=$c599 consume_rc=$d599; t+600: count=$c600 consume_rc=$a600 count_after=$c600b; t+601 consume_rc=$d601"
KAKAO_FAKE_NOW=$((T0+610)); c610=$(budget_count)
KAKAO_FAKE_NOW=$((T0+620)); c620=$(budget_count)
KAKAO_FAKE_NOW=$((T0+1300)); c1300=$(budget_count)
ck entries_expire_individually "$([ "$c610" = 2 ] && [ "$c620" = 1 ] && [ "$c1300" = 0 ] && echo 1 || echo 0)" "t+610: $c610 t+620: $c620 t+1300: $c1300 (entries at +10,+20,+600 dropped one by one)"

# 4: reset after 10 min of CONTINUOUS ready (an entry newer than the streak start keeps count>0; BLOCKED also lifts)
fresh; S=$((T0+5000))
KAKAO_FAKE_NOW=$S; ready_streak_update 1
KAKAO_FAKE_NOW=$((S+1)); budget_consume relaunch s1; BLOCKED=1
KAKAO_FAKE_NOW=$((S+599)); ready_streak_update 1 >/dev/null; cb=$(budget_count); bb=$BLOCKED
KAKAO_FAKE_NOW=$((S+600)); out=$(ready_streak_update 1; printf 'BL=%s LR=%s\n' "$BLOCKED" "$LAST_RESET"); ready_streak_update 1 >/dev/null
ca=$(budget_count)
ck ready_600s_resets_budget "$([ "$cb" = 1 ] && [ "$bb" = 1 ] && [ "$ca" = 0 ] && [ "$BLOCKED" = 0 ] && case "$LAST_RESET" in *:ready_600s) true ;; *) false ;; esac && echo 1 || echo 0)" "t+599: count=$cb blocked=$bb; t+600: count=$ca blocked=$BLOCKED last_reset=$LAST_RESET"
ck reset_event_logged "$([ -n "$(printf '%s' "$out" | grep 'event=budget_reset reason=ready_600s cleared_entries=1')" ] && grep -q 'event=budget_reset reason=ready_600s' "$KAKAO_STATE_DIR/last-failure.log" && echo 1 || echo 0)" "stdout and last-failure.log carry event=budget_reset reason=ready_600s cleared_entries=1"
fresh; S2=$((T0+9000))
KAKAO_FAKE_NOW=$S2; ready_streak_update 1
BLOCKED=1
KAKAO_FAKE_NOW=$((S2+300)); ready_streak_update 0
KAKAO_FAKE_NOW=$((S2+301)); ready_streak_update 1
KAKAO_FAKE_NOW=$((S2+601)); ready_streak_update 1 >/dev/null; nb=$BLOCKED
KAKAO_FAKE_NOW=$((S2+900)); ready_streak_update 1 >/dev/null; nb2=$BLOCKED
KAKAO_FAKE_NOW=$((S2+901)); ready_streak_update 1 >/dev/null; nb3=$BLOCKED
ck interrupted_ready_streak_does_not_reset "$([ "$nb" = 1 ] && [ "$nb2" = 1 ] && [ "$nb3" = 0 ] && echo 1 || echo 0)" "ready,notready@+300,ready@+301: blocked at +601=$nb (601s since first ready, 300s continuous) +900=$nb2, lifted at +901=$nb3 (600s continuous)"

# 5: manual-recovery marker
fresh; KAKAO_FAKE_NOW=$T0
budget_consume relaunch m1; KAKAO_FAKE_NOW=$((T0+1)); budget_consume relaunch m2; KAKAO_FAKE_NOW=$((T0+2)); budget_consume relaunch m3
check_manual_recovery; nm=$?; cn=$(budget_count)
touch "$KAKAO_STATE_DIR/manual-recovery"
check_manual_recovery >"$KAKAO_STATE_DIR/mr.out"; mr=$?
ck manual_marker_resets "$([ "$nm" = 1 ] && [ "$cn" = 3 ] && [ "$mr" = 0 ] && [ "$(budget_count)" = 0 ] && [ ! -e "$KAKAO_STATE_DIR/manual-recovery" ] && case "$LAST_RESET" in *:manual_recovery) true ;; *) false ;; esac && echo 1 || echo 0)" "no marker: rc=$nm count=$cn; with marker: rc=$mr count=$(budget_count) marker_removed=$([ ! -e "$KAKAO_STATE_DIR/manual-recovery" ] && echo yes || echo no) last_reset=$LAST_RESET"

# 6: new image ID
fresh; export KAKAO_IMAGE_ID=img-A; check_image_change; f1=$(cat "$KAKAO_STATE_DIR/image_id")
KAKAO_FAKE_NOW=$T0; budget_consume relaunch i1; KAKAO_FAKE_NOW=$((T0+1)); budget_consume relaunch i2; KAKAO_FAKE_NOW=$((T0+2)); budget_consume relaunch i3
check_image_change; same=$(budget_count); ex0=$(yn budget_exhausted)
export KAKAO_IMAGE_ID=img-B; check_image_change >"$KAKAO_STATE_DIR/ic.out"; after=$(budget_count); ex1=$(yn budget_exhausted); f2=$(cat "$KAKAO_STATE_DIR/image_id")
ck new_image_id_resets "$([ "$f1" = id:img-A ] && [ "$same" = 3 ] && [ "$ex0" = 1 ] && [ "$after" = 0 ] && [ "$ex1" = 0 ] && [ "$f2" = id:img-B ] && grep -q 'event=budget_reset reason=new_image' "$KAKAO_STATE_DIR/ic.out" && echo 1 || echo 0)" "same id keeps count=$same exhausted=$ex0; changed id: count=$after exhausted=$ex1 stored=$f2 $(grep -o 'reason=new_image cleared_entries=[0-9]*' "$KAKAO_STATE_DIR/ic.out")"
unset KAKAO_IMAGE_ID; fp=$(current_image_id)
ck fingerprint_when_no_image_id_given "$(case "$fp" in fp:????????????????) echo 1 ;; *) echo 0 ;; esac)" "fingerprint format ok: ${fp%%:*}:<16 hex>"

# 7: docker stop (SIGTERM -> on_signal) never counts
fresh; KAKAO_FAKE_NOW=$T0; budget_consume relaunch t1; c0=$(budget_count)
out=$(on_signal TERM); rc=$?; c1=$(budget_count)
ck docker_stop_not_counted "$([ "$rc" = 0 ] && [ "$c0" = 1 ] && [ "$c1" = 1 ] && printf '%s' "$out" | grep -q 'event=manual_stop signal=TERM counted=0' && echo 1 || echo 0)" "on_signal TERM: exit=$rc count $c0 -> $c1; stdout: $(printf '%s' "$out" | sed 's/^.*event=/event=/')"
ck stop_path_never_touches_budget "$([ "$(declare -f on_signal on_exit cleanup_all | grep -c 'budget_')" = 0 ] && declare -f main | grep -q "trap 'on_signal TERM' TERM" && echo 1 || echo 0)" "on_signal/on_exit/cleanup_all contain no budget_* call; main traps TERM -> on_signal"
echo DONE
EOS
}

run_circuit_unit() { # prints the part JSON
  local started out rc raw="$WORK/circuit.unit.out"; started=$(now_utc)
  log "circuit (a): fake-clock unit run inside a throwaway candidate container (no ports, no volume, no network)"
  circuit_unit_script | qa_mutate timeout 120 docker run --rm -i --network none --entrypoint bash "$CANDIDATE_TAG" -s >"$raw" 2>"$WORK/circuit.unit.err"; rc=$?
  jq -R -s -c --arg started "$started" --arg finished "$(now_utc)" --argjson rc "$rc" --arg wt "$(sha_of "$REPO_ROOT/docker/entrypoint.sh")" --arg cand "$CANDIDATE_TAG" '
    split("\n") as $l
    | ([$l[] | select(startswith("CHECK\t")) | split("\t") | {name:.[1], passed:(.[2] == "1"), detail:(.[3:] | join(" "))}]) as $checks
    | ([$l[] | select(startswith("SHA\t")) | split("\t")[1]] | first // "") as $sha
    | { part:"unit", method:"real budget_consume/budget_count/budget_exhausted/budget_reset/ready_streak_update/check_manual_recovery/check_image_change/on_signal sourced from /usr/local/bin/kakao-entrypoint with KAKAO_FAKE_NOW (fake clock); throwaway container of the candidate image",
        started_at:$started, finished_at:$finished, image:$cand, docker_run_exit_code:$rc,
        sourced_file_sha256:$sha, worktree_entrypoint_sha256:$wt, sourced_file_equals_worktree:($sha == $wt),
        config:([$l[] | select(startswith("CFG\t")) | split("\t")[1]] | first // null),
        script_finished:(($l | index("DONE")) != null),
        checks:$checks,
        passed:(($checks | length) >= 9 and ($checks | all(.passed)) and ($l | index("DONE")) != null and $rc == 0 and $sha == $wt) }' "$raw"
}

# (b) real isolated consecutive failures until the shared budget is exhausted
wait_monitor_ack() { # <expected recovery_count> [deadline-s]: the monitor itself reports ready again (its pending recovery is cleared)
  local dl=$((SECONDS + ${2:-60})) st
  while :; do
    st=$(runtime_state_json)
    printf '%s' "$st" | jq -e --arg n "$1" '.state.phase == "ready" and .state.recovery_count == $n' >/dev/null 2>&1 && return 0
    [ "$SECONDS" -ge "$dl" ] && return 1
    sleep 3
  done
}

run_circuit_real() { # prints the part JSON
  local started; started=$(now_utc)
  log "circuit (b): fresh volume, repeated isolated KakaoTalk.exe kills until the budget is exhausted"
  if ! stack_fresh_ready; then jq -n -c --arg r "$READY_REASON" '{part:"real", passed:false, error:$r}'; return 0; fi
  local cid=$CASE_CID line rc0 started0 kills="$WORK/circuit.kills.jsonl" k old s T0 rec rec_s ack st
  wait_window || true
  line=$(container_inspect_line "$cid"); set -- $line; rc0=${2:-0}; started0=${3:-}
  : >"$kills"
  for k in 1 2 3; do
    old=$(pidmap "$(proc_survey "$cid")" | jq -c '.app')
    if [ "$(printf '%s' "$old" | jq 'length')" -lt 1 ]; then jq -n -c --argjson k "$k" '{n:$k, error:"no KakaoTalk.exe to kill"}' >>"$kills"; break; fi
    log "failure $k/3: KILL KakaoTalk.exe $old"
    qa_mutate timeout 20 docker exec "$cid" kill -KILL $(printf '%s' "$old" | jq -r 'join(" ")') || true
    T0=$SECONDS; rec=false; rec_s=null
    while :; do
      s=$(take_sample "$T0")
      if printf '%s' "$s" | jq -e --argjson old "$old" '(.probe.rc == 0 and .probe.phase == "ready" and .http_status == 200 and .rfb_ok == true) and ((.pids.app | length) > 0) and (((.pids.app - $old) | length) == (.pids.app | length))' >/dev/null 2>&1; then
        rec=true; rec_s=$((SECONDS - T0)); break
      fi
      [ $((SECONDS - T0)) -ge "$RECOVERY_DEADLINE" ] && break
      sleep "$POLL_INTERVAL"
    done
    ack=false; [ "$rec" = true ] && wait_monitor_ack "$k" 60 && ack=true
    st=$(runtime_state_json); [ -n "$st" ] || st=null
    jq -n -c --argjson k "$k" --argjson old "$old" --argjson rec "$rec" --argjson rec_s "$rec_s" --argjson ack "$ack" --argjson st "$st" \
      '{n:$k, killed_pids:$old, recovered_ready_and_new_app_pid:$rec, seconds_to_ready:$rec_s, monitor_ack_ready:$ack,
        recovery_count_after:($st.state.recovery_count // null), budget_entries_after:($st.budget_entries // [])}' >>"$kills"
    [ "$ack" = true ] || break
  done
  # failure 4: budget is used up -> the monitor must block, not act
  local old4 t4=$SECONDS blocked=false blk_s=null bst=null
  old4=$(pidmap "$(proc_survey "$cid")" | jq -c '.app')
  if [ "$(printf '%s' "$old4" | jq 'length')" -ge 1 ] && [ "$(jq -s 'length == 3 and all(.[]; .monitor_ack_ready == true)' "$kills")" = true ]; then
    log "failure 4: KILL KakaoTalk.exe $old4 (budget exhausted -> blocked expected)"
    qa_mutate timeout 20 docker exec "$cid" kill -KILL $(printf '%s' "$old4" | jq -r 'join(" ")') || true
    t4=$SECONDS
    while :; do
      bst=$(runtime_state_json)
      if printf '%s' "$bst" | jq -e '.state.phase == "blocked" and .state.blocked == "1"' >/dev/null 2>&1; then blocked=true; blk_s=$((SECONDS - t4)); break; fi
      [ $((SECONDS - t4)) -ge 90 ] && break
      sleep 2
    done
  fi
  [ -n "$bst" ] || bst=null
  # observation window: blocked means no further automatic action (time itself is the behavior)
  local ws="$WORK/circuit.window.jsonl" w0=$SECONDS wend n lines0 act0 obs_s
  : >"$ws"; lines0=$(runtime_total_lines); act0=$(log_action_count)
  wend=$((SECONDS + CIRCUIT_OBSERVE))
  if [ "$blocked" = true ]; then
    while :; do
      s=$(take_sample "$w0"); st=$(runtime_state_json); [ -n "$st" ] || st=null; n=$(runtime_total_lines)
      jq -n -c --argjson s "$s" --argjson st "$st" --argjson n "$n" \
        '$s + {state:{phase:$st.state.phase, blocked:$st.state.blocked, reason:$st.state.reason, monitor_pid:$st.state.monitor_pid, recovery_count:$st.state.recovery_count, budget_entries:(($st.budget_entries // []) | length)}, runtime_log_lines_total:$n}' >>"$ws"
      [ "$SECONDS" -ge "$wend" ] && break
      sleep 5
    done
  fi
  obs_s=$((SECONDS - w0))
  local act1 lines1 rc1 started1 fstate flogs health
  act1=$(log_action_count); lines1=$(runtime_total_lines)
  line=$(container_inspect_line "$QA_CONTAINER"); set -- $line; rc1=${2:--1}; started1=${3:-}
  fstate=$(runtime_state_json); [ -n "$fstate" ] || fstate=null
  flogs=$(runtime_log_lines); [ -n "$flogs" ] || flogs='[]'
  health=$(health_status)
  # a manual docker stop of the blocked container: exits 0, is not restarted, and is not counted
  local stop_rc=0 stop_t0=$SECONDS stop_secs exit_code stayed=true l o_st o_rc obs_end bud_after
  qa_mutate timeout 60 docker stop -t 30 "$cid" >/dev/null 2>&1 || stop_rc=$?
  stop_secs=$((SECONDS - stop_t0))
  exit_code=$(docker inspect "$cid" --format '{{.State.ExitCode}}' 2>/dev/null)
  obs_end=$((SECONDS + 20))
  while [ "$SECONDS" -lt "$obs_end" ]; do
    l=$(container_inspect_line "$cid"); set -- $l; o_st=${1:-gone}; o_rc=${2:--1}
    { [ "$o_st" = exited ] && [ "$o_rc" = "$rc1" ]; } || stayed=false
    sleep "$POLL_INTERVAL"
  done
  bud_after=$(timeout 20 docker cp "$cid:/data/runtime-state/budget.log" - 2>/dev/null | tar -xO 2>/dev/null | grep -c . || true)
  local stop_logs; stop_logs=$(timeout 30 docker logs "$cid" 2>&1 | grep -a -c 'event=manual_stop signal=TERM counted=0' || true)
  jq -n -c --arg started "$started" --arg finished "$(now_utc)" --argjson rc0 "$rc0" --argjson rc1 "$rc1" --arg started0 "$started0" --arg started1 "$started1" \
    --slurpfile kills "$kills" --slurpfile win "$ws" --argjson blocked "$blocked" --argjson blk_s "$blk_s" --argjson bst "$bst" --argjson fstate "$fstate" \
    --argjson flogs "$flogs" --argjson act0 "$act0" --argjson act1 "$act1" --argjson lines0 "$lines0" --argjson lines1 "$lines1" --argjson obs_s "$obs_s" \
    --argjson cobs "$CIRCUIT_OBSERVE" --arg health "$health" --argjson stop_rc "$stop_rc" --argjson stop_secs "$stop_secs" --arg exit_code "$exit_code" \
    --argjson stayed "$stayed" --argjson bud_after "${bud_after:-0}" --argjson stop_logs "${stop_logs:-0}" --argjson old4 "$old4" --argjson interval "$NF_MONITOR_INTERVAL" '
    ($kills) as $k | ($win) as $w
    | { part:"real", started_at:$started, finished_at:$finished,
        method:"fresh QA volume; KakaoTalk.exe is KILLed 3x (each only after the previous recovery was ready AND the monitor reported ready again), then a 4th time with the shared budget (3 per 10 min) used up",
        failures:$k, fourth_failure:{killed_pids:$old4, blocked_reached:$blocked, seconds_to_blocked:$blk_s, state_when_blocked:$bst.state, budget_entries_when_blocked:($bst.budget_entries // [])},
        observation:{window_s:$obs_s, requested_s:$cobs, monitor_intervals_covered:(($obs_s / $interval) | floor), samples:$w,
                     automatic_action_records_before:$act0, automatic_action_records_after:$act1, runtime_log_lines_before:$lines0, runtime_log_lines_after:$lines1},
        container:{restart_count_before:$rc0, restart_count_after_window:$rc1, started_at_before:$started0, started_at_after_window:$started1, docker_health_when_blocked:$health},
        final_runtime_state:$fstate, runtime_log_lines:$flogs,
        manual_stop_while_blocked:{docker_stop_exit_status:$stop_rc, seconds:$stop_secs, container_exit_code:($exit_code | tonumber? // null), stayed_exited_20s_no_restart:$stayed,
                                   budget_entries_after_stop:$bud_after, manual_stop_counted0_log_records:$stop_logs},
        assertions:{
          failures_1_to_3_each_recovered_isolated:(($k | length) == 3 and ($k | all(.[]; .recovered_ready_and_new_app_pid == true and .monitor_ack_ready == true))),
          recovery_count_grew_one_per_failure:(($k | map(.recovery_count_after)) == ["1","2","3"]),
          budget_exactly_3_relaunch_entries_when_blocked:((($bst.budget_entries // []) | length) == 3 and (($bst.budget_entries // []) | all(.[]; test(" app_relaunch ")))),
          fourth_failure_blocked_phase_and_flag:($blocked and $bst.state.phase == "blocked" and $bst.state.blocked == "1" and $bst.state.layer == "app"),
          window_long_enough:($obs_s >= $cobs and $cobs >= (9 * $interval) and ($w | length) >= 5),
          no_process_started_in_window:($w | length > 0 and all(.[]; (.pids.app | length) == 0)),
          every_window_sample_probe_phase_blocked:($w | length > 0 and all(.[]; .probe.phase == "blocked")),
          budget_and_recovery_count_unchanged_in_window:($w | length > 0 and all(.[]; .state.budget_entries == 3 and .state.recovery_count == "3")),
          monitor_pid_unchanged_in_window:(($w | map(.state.monitor_pid) | unique | length) == 1),
          no_new_automatic_action_records_in_window:($act1 == $act0 and $act1 == 3),
          no_log_spam_no_loop_in_window:($lines0 == $lines1 and ($w | map(.runtime_log_lines_total) | unique | length) == 1),
          container_not_restart_looping:($rc0 == 0 and $rc1 == 0 and ($w | length > 0 and all(.[]; .restart_count == 0 and .container_status == "running")) and $started0 == $started1),
          docker_stop_while_blocked_exit0_no_restart:($stop_rc == 0 and $exit_code == "0" and $stop_secs < 30 and $stayed),
          docker_stop_not_counted:($bud_after == 3 and $stop_logs >= 1)
        } } | .passed = (.assertions | all)'
}

cmd_circuit() { # [unit|real]
  need_tools; resolve_guard; use_candidate
  local parts=("$@") p
  [ "${#parts[@]}" -gt 0 ] || parts=(unit real)
  for p in "${parts[@]}"; do case "$p" in unit|real) ;; *) log "unknown circuit part '$p' (valid: unit real)"; exit "$EX_USAGE" ;; esac; done
  R_STARTED=$(now_utc); R_PB=$(prod_snapshot); R_WB=$(worktree_state)
  ensure_candidate
  SRC_JSON=$(source_light)
  local results="$WORK/circuit.parts.jsonl" f rc; : >"$results"
  for p in "${parts[@]}"; do
    f="$WORK/circuit.part.$p.json"; rm -f "$f"
    if [ "$p" = unit ]; then ( run_circuit_unit ) >"$f"; rc=$?; else ( run_circuit_real ) >"$f"; rc=$?; fi
    if ! jq -e . "$f" >/dev/null 2>&1; then jq -n -c --arg p "$p" --argjson rc "$rc" '{part:$p, passed:false, error:"part aborted without result", subshell_exit:$rc}' >"$f"; fi
    jq -c '. + {case:.part}' "$f" >>"$results"
    log "circuit $p: passed=$(jq -r '.passed' "$f")"
  done
  local out=task-2-circuit.json extra
  [ "$#" -gt 0 ] && out="task-2-circuit-$(IFS=-; printf '%s' "${parts[*]}")-repeat.json"
  extra=$(jq -n -c --argjson adv "$ADVERSARIAL_COMMON" --argjson subset "$([ "$#" -gt 0 ] && echo true || echo false)" '{subset_run:$subset,
    adversarial:($adv + {repeated_interruptions:{probed:true, finding:"circuit breaker: 3 automatic actions per 10 min across ALL layers and boot paths; the 4th failure only sets phase=blocked, no process is started, the log does not grow, the container is not restarted (RestartCount stays 0) and docker stop still exits 0 uncounted"}})}')
  emit_receipt task-2-circuit "bash scripts/qa-runtime.sh circuit${*:+ $*}" "$out" "$results" "$extra"
}

############################ todo 2 part B: init-failure ############################

die_events() { # <since-epoch> -> JSON [{time, exit_code}] of container `die` events of the QA container
  timeout 30 docker events --since "$1" --until "$(date +%s)" --filter "container=$QA_CONTAINER" --filter event=die --format '{{json .}}' 2>/dev/null \
    | jq -s -c '[.[] | {time:.time, exit_code:(.Actor.Attributes.exitCode // null)}]'
}

# wineboot failure injection: KAKAO_WINEBOOT_TIMEOUT=0.2 (passed through docker-compose.qa.yml as QA_WINEBOOT_TIMEOUT) makes the
# bounded `timeout ... wineboot -u` of init_wine_prefix expire (rc 124) before wineboot can possibly finish. That is exactly the
# `|| return 1` path of any non-zero wineboot exit; no production code path is patched.
run_init_failure_case() { # prints the case JSON (runs in a subshell)
  local name=init_failure started since cid
  started=$(now_utc)
  log "init-failure: fresh volume, KAKAO_WINEBOOT_TIMEOUT=$INIT_WINEBOOT_TIMEOUT (wineboot cannot finish)"
  STALE_CLEANED=false; prep_fresh
  export QA_WINEBOOT_TIMEOUT="$INIT_WINEBOOT_TIMEOUT"
  since=$(( $(date +%s) - 2 ))
  qa_up || { case_error "$name" "compose up failed"; return 0; }
  cid=$(docker inspect "$QA_CONTAINER" --format '{{.Id}}' 2>/dev/null)
  { [ -n "$cid" ] && [ "$(qa_label_project container "$QA_CONTAINER")" = "$QA_PROJECT" ]; } || { case_error "$name" "QA container missing or without QA label"; return 0; }
  local T0=$SECONDS blocked=false blk_s=null st=null
  while :; do
    st=$(runtime_state_json)
    if printf '%s' "$st" | jq -e '.state.phase == "blocked" and .state.blocked == "1"' >/dev/null 2>&1; then blocked=true; blk_s=$((SECONDS - T0)); break; fi
    [ $((SECONDS - T0)) -ge "$INIT_BLOCK_DEADLINE" ] && break
    sleep "$POLL_INTERVAL"
  done
  log "init-failure: blocked=$blocked after ${blk_s}s"
  local line rc0 started0 ev0 probe
  line=$(container_inspect_line "$QA_CONTAINER"); set -- $line; rc0=${2:--1}; started0=${3:-}
  ev0=$(die_events "$since"); probe=$(probe_json)
  local samples="$WORK/samples.init.jsonl" w0=$SECONDS l o_st o_rc o_started stable=true
  : >"$samples"
  if [ "$blocked" = true ]; then
    while :; do
      l=$(container_inspect_line "$QA_CONTAINER"); set -- $l; o_st=${1:-gone}; o_rc=${2:--1}; o_started=${3:-}
      jq -n -c --argjson t "$((SECONDS - w0))" --arg st "$o_st" --argjson rc "$o_rc" --arg started "$o_started" '{t_s:$t, container_status:$st, restart_count:$rc, started_at:$started}' >>"$samples"
      { [ "$o_st" = running ] && [ "$o_rc" = "$rc0" ] && [ "$o_started" = "$started0" ]; } || stable=false
      [ $((SECONDS - w0)) -ge "$INIT_OBSERVE" ] && break
      sleep 5
    done
  fi
  local obs_s=$((SECONDS - w0)) ev1 fstate flogs banner failrec envs pids rc1 started1 health
  ev1=$(die_events "$since")
  fstate=$(runtime_state_json); [ -n "$fstate" ] || fstate=null
  flogs=$(runtime_log_lines); [ -n "$flogs" ] || flogs='[]'
  banner=$(timeout 30 docker logs "$QA_CONTAINER" 2>&1 | grep -a -c 'KakaoTalk Web is up') || true
  failrec=$(timeout 30 docker logs "$QA_CONTAINER" 2>&1 | grep -a -c 'reason=wine_init_failed .*action=exit code=10') || true
  envs=$(kakao_env_overrides); [ -n "$envs" ] || envs='["unreadable"]'
  pids=$(pidmap "$(proc_survey "$QA_CONTAINER")")
  line=$(container_inspect_line "$QA_CONTAINER"); set -- $line; rc1=${2:--1}; started1=${3:-}
  health=$(health_status)
  jq -n -c --arg name "$name" --arg started "$started" --arg finished "$(now_utc)" --argjson blocked "$blocked" --argjson blk_s "$blk_s" \
    --argjson rc0 "$rc0" --argjson rc1 "${rc1:--1}" --arg started0 "$started0" --arg started1 "$started1" --argjson ev0 "$ev0" --argjson ev1 "$ev1" \
    --argjson probe "$probe" --argjson obs_s "$obs_s" --argjson want_obs "$INIT_OBSERVE" --argjson stable "$stable" --slurpfile samples "$samples" \
    --argjson fstate "$fstate" --argjson flogs "$flogs" --argjson banner "${banner:-0}" --argjson failrec "${failrec:-0}" --argjson envs "$envs" \
    --argjson pids "$pids" --arg health "$health" --arg inj "$INIT_WINEBOOT_TIMEOUT" --arg cid "$cid" '
    ($fstate.state // {}) as $s | ($fstate.budget_entries // []) as $bud | ($s.budget_max // "3" | tonumber) as $max
    | { case:$name, started_at:$started, finished_at:$finished,
        fault:{kind:"wineboot failure", injection:("KAKAO_WINEBOOT_TIMEOUT=" + $inj + " via docker-compose.qa.yml QA_WINEBOOT_TIMEOUT"), mechanism:"bounded wineboot expires (timeout rc 124) before it can finish -> init_wine_prefix returns 1 -> fail_boot", expected_exit_code:10},
        seconds_to_blocked:$blk_s, die_events_when_blocked:$ev0, die_events_after_window:$ev1, probe_when_blocked:$probe,
        container:{id:$cid, restart_count_when_blocked:$rc0, restart_count_after_window:$rc1, started_at_when_blocked:$started0, started_at_after_window:$started1, docker_health:$health},
        observation:{window_s:$obs_s, requested_s:$want_obs, samples:$samples},
        runtime_state_after:$fstate, runtime_log_lines:$flogs, pids_after:$pids,
        counts:{init_failed_exit_records:$failrec, up_banner_lines:$banner}, kakao_env_overrides:$envs,
        assertions:{
          failure_injected_through_env_only:($envs == ["KAKAO_WINEBOOT_TIMEOUT=" + $inj]),
          wine_initialized_marker_not_created:($s != {} and $fstate.wine_initialized_marker == "absent"),
          every_boot_exit_nonzero_code_10:(($ev1 | length) >= 1 and ($ev1 | all(.[]; .exit_code == "10"))),
          exits_equal_budget_and_restart_count:(($ev1 | length) == $max and $rc1 == $max),
          budget_consumed_by_each_failed_boot:(($bud | length) == $max and ($bud | all(.[]; test(" boot_failure wine_init_failed$")))),
          failure_records_logged_per_boot:($failrec == $max),
          eventually_blocked:($blocked and $s.phase == "blocked" and $s.blocked == "1" and $s.layer == "x" and $s.reason == "budget_exhausted_at_boot" and $probe.phase == "blocked"),
          no_boot_loop_after_block:($stable and $obs_s >= $want_obs and ($ev1 | length) == ($ev0 | length) and $rc1 == $rc0 and $started0 == $started1),
          restart_count_bounded_by_budget:($rc1 >= 0 and $rc1 <= $max),
          diagnostics_in_failure_log:(($fstate.failure_log_tail // []) | any(.[]; contains("reason=wine_init_failed"))),
          kakaotalk_never_launched:(($pids.app | length) == 0 and $banner == 0)
        } } | .passed = (.assertions | all)'
}

cmd_init_failure() {
  need_tools; resolve_guard; use_candidate
  R_STARTED=$(now_utc); R_PB=$(prod_snapshot); R_WB=$(worktree_state)
  ensure_candidate
  SRC_JSON=$(source_light)
  local results="$WORK/init.cases.jsonl" f="$WORK/init.case.json" rc; : >"$results"
  ( run_init_failure_case ) >"$f"; rc=$?
  if ! jq -e . "$f" >/dev/null 2>&1; then case_error init_failure "case aborted without result (subshell exit $rc)" >"$f"; fi
  jq -c . "$f" >>"$results"
  local extra
  extra=$(jq -n -c --argjson adv "$ADVERSARIAL_COMMON" '{adversarial:($adv + {repeated_interruptions:{probed:true, finding:"boot failures share the one runtime budget: 3 failed boots (exit 10, restart policy returns), the 4th boot refuses to act (phase=blocked, container stays up, RestartCount stops at 3)"}})}')
  emit_receipt task-2-init-failure "bash scripts/qa-runtime.sh init-failure" task-2-init-failure.json "$results" "$extra"
}

############################ todo 2 part B: mutation ############################

mutant_teardown() { # idempotent: QA stack on the mutant image, the mutant tag and the temp copy
  [ -n "$MUTANT_DIR" ] && rm -rf "$MUTANT_DIR"
  MUTANT_DIR=""
  if [ "$GUARD_PASSED" = 1 ] && docker image inspect "$MUTANT_TAG" >/dev/null 2>&1; then
    timeout 180 docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans --timeout 30 >/dev/null 2>&1 || true
    timeout 60 docker rmi "$MUTANT_TAG" >/dev/null 2>&1 || true
  fi
  MUTANT_BUILT=0
}

make_mutant_copy() { # <dest-dir>: temp copy of docker/ with the vnc/web recovery branch made a no-op (relaunch_vnc / relaunch_web)
  mkdir -p "$1/docker" || return 1
  cp "$REPO_ROOT/docker/run-kakao.sh" "$REPO_ROOT/docker/healthcheck.sh" "$1/docker/" || return 1
  awk '
    /^relaunch_vnc\(\) \{/ { print "relaunch_vnc() { :; } # MUTANT: recovery branch removed"; n++; next }
    /^relaunch_web\(\) \{/ { print "relaunch_web() { :; } # MUTANT: recovery branch removed"; n++; next }
    { print }
    END { exit (n == 2 ? 0 : 3) }' "$REPO_ROOT/docker/entrypoint.sh" >"$1/docker/entrypoint.sh" || return 1
  chmod 0755 "$1/docker/entrypoint.sh" "$1/docker/run-kakao.sh" "$1/docker/healthcheck.sh"
  printf '%s\n' \
    'FROM kakaotalk-wine:reliability-baseline' \
    'COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/kakao-entrypoint' \
    'COPY --chmod=0755 docker/run-kakao.sh /usr/local/bin/run-kakao' \
    'COPY --chmod=0755 docker/healthcheck.sh /usr/local/bin/kakao-healthcheck' \
    'HEALTHCHECK --interval=10s --timeout=12s --start-period=90s --retries=3 CMD ["/usr/local/bin/kakao-healthcheck"]' >"$1/Dockerfile"
}

cmd_mutation() {
  need_tools; resolve_guard; use_candidate
  R_STARTED=$(now_utc); R_PB=$(prod_snapshot); R_WB=$(worktree_state)
  case "$MUTANT_TAG" in "$BASELINE_TAG"|"$CANDIDATE_TAG"|"$PROD_IMAGE_TAG") die_env "mutant tag collides with a protected tag" ;; esac
  ensure_candidate
  SRC_JSON=$(source_light)
  local base0 cand0 stale=false
  base0=$(img_id "$BASELINE_TAG"); cand0=$(img_id "$CANDIDATE_TAG")
  if docker image inspect "$MUTANT_TAG" >/dev/null 2>&1; then stale=true; log "stale mutant tag found; removing it first"; MUTANT_BUILT=1; mutant_teardown; fi
  local ctrl mut
  log "mutation: control run of the x11vnc recovery case on the REAL candidate"
  ctrl=$( ( run_fault_case x11vnc ) ); printf '%s' "$ctrl" | jq -e . >/dev/null 2>&1 || ctrl=$(case_error x11vnc "control case aborted without result")
  MUTANT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kakao-mutant.XXXXXX") || die_env "mktemp failed"
  local mdir=$MUTANT_DIR mutated=false syntax=false diffl='[]' mhash="" mimg="" build_rc=0
  if make_mutant_copy "$MUTANT_DIR"; then
    mutated=true
    bash -n "$MUTANT_DIR/docker/entrypoint.sh" 2>/dev/null && syntax=true
    diffl=$(diff "$REPO_ROOT/docker/entrypoint.sh" "$MUTANT_DIR/docker/entrypoint.sh" | grep -E '^[<>]' | jq -R -s -c 'split("\n") | map(select(length > 0))')
    mhash=$(sha_of "$MUTANT_DIR/docker/entrypoint.sh")
  fi
  local mut_embedded=null
  if [ "$mutated" = true ] && [ "$syntax" = true ]; then
    MUTANT_BUILT=1
    qa_mutate timeout 300 docker build --pull=false -t "$MUTANT_TAG" "$MUTANT_DIR" >"$WORK/mutant.build.log" 2>&1 || build_rc=$?
    mimg=$(img_id "$MUTANT_TAG")
    if [ "$build_rc" = 0 ] && [ -n "$mimg" ]; then
      mut_embedded=$(qa_mutate timeout 60 docker run --rm --network none --entrypoint sh "$MUTANT_TAG" -c 'echo "$(sha256sum /usr/local/bin/kakao-entrypoint | cut -d" " -f1) $(grep -c "MUTANT: recovery branch removed" /usr/local/bin/kakao-entrypoint)"' 2>/dev/null \
        | jq -R -s -c 'split(" ") | {sha256:.[0], mutant_marker_lines:(.[1] | rtrimstr("\n") | tonumber? // null)}')
      [ -n "$mut_embedded" ] || mut_embedded=null
      log "mutation: x11vnc recovery case on the MUTANT image (must FAIL)"
      mut=$( ( export QA_IMAGE=$MUTANT_TAG; resolve_guard; CASE_IMAGE_TAG=$MUTANT_TAG; run_fault_case x11vnc ) )
    fi
  fi
  printf '%s' "${mut:-}" | jq -e . >/dev/null 2>&1 || mut=$(case_error x11vnc "mutant case did not run (mutated=$mutated syntax=$syntax build_rc=$build_rc)")
  # teardown, then verify it
  mutant_teardown
  local tag_after dir_gone=false c v base1 cand1 recref
  tag_after=$(img_id "$MUTANT_TAG"); [ -d "$mdir" ] || dir_gone=true
  c=$(docker ps -a -q --filter "name=^/${QA_CONTAINER}\$" | wc -l); v=$(docker volume ls -q --filter "name=^${QA_VOLUME}\$" | wc -l)
  base1=$(img_id "$BASELINE_TAG"); cand1=$(img_id "$CANDIDATE_TAG")
  recref=$(jq -c '[.cases[] | select(.case == "x11vnc")] | first | {receipt:"task-2-recovery.json", passed:.passed, seconds_to_ready:.assertions.seconds_from_injection_to_ready_and_rfb}' "$(evidence_dir)/task-2-recovery.json" 2>/dev/null)
  [ -n "$recref" ] || recref=null
  local results="$WORK/mut.cases.jsonl"; : >"$results"
  jq -n -c --argjson ctrl "$ctrl" --argjson mut "$mut" --argjson diffl "$diffl" --argjson mutated "$mutated" --argjson syntax "$syntax" --arg mhash "$mhash" \
    --arg wt "$(sha_of "$REPO_ROOT/docker/entrypoint.sh")" --argjson emb "$mut_embedded" --arg mimg "$mimg" --argjson build_rc "$build_rc" --argjson stale "$stale" \
    --arg tag_after "$tag_after" --argjson dir_gone "$dir_gone" --argjson c "$c" --argjson v "$v" --arg base0 "$base0" --arg base1 "$base1" --arg cand0 "$cand0" --arg cand1 "$cand1" \
    --arg mtag "$MUTANT_TAG" --argjson recref "$recref" '
    ([$mut.assertions // {} | to_entries[] | select(.value == false) | .key]) as $failed
    | { case:"x11vnc_recovery_mutation", adversarial:"mutation: recovery branch removed must make the harness fail",
        mutation:{description:"relaunch_vnc and relaunch_web made no-ops in a temp copy outside the worktree; image built FROM the baseline tag + the three docker scripts only",
                  mutant_tag:$mtag, mutant_image_id:$mimg, diff_lines:$diffl, mutant_entrypoint_sha256:$mhash, worktree_entrypoint_sha256:$wt,
                  embedded_in_image:$emb, docker_build_exit_code:$build_rc, stale_mutant_tag_removed_first:$stale},
        control_candidate_case:$ctrl, mutant_case:$mut, mutant_failed_assertions:$failed, recovery_receipt_reference:$recref,
        teardown:{mutant_tag_after:$tag_after, mutant_tag_removed:($tag_after == ""), temp_dir_removed:$dir_gone, qa_container_remaining:$c, qa_volume_remaining:$v,
                  baseline_id_before:$base0, baseline_id_after:$base1, candidate_id_before:$cand0, candidate_id_after:$cand1},
        assertions:{
          candidate_control_passes_same_case:($ctrl.passed == true),
          mutation_applied_exactly_two_lines_and_syntax_ok:($mutated and $syntax and (($diffl | length) == 4) and ($mhash != "") and ($mhash != $wt)),
          mutant_image_built_and_embeds_mutation:($build_rc == 0 and ($mimg | length) > 0 and ($emb.sha256 // "") == $mhash and ($emb.mutant_marker_lines // 0) == 2),
          harness_reports_failure_for_mutant:($mut.passed == false and ($mut.error == null)),
          failure_caused_by_recovery_behavior:(($failed | length) > 0 and ($failed | any(. == "restart_count_as_expected" or . == "other_layers_unchanged" or . == "recovered_with_probe_ready_and_rfb_ok" or . == "budget_entries_exactly_one"))),
          mutant_tag_removed:($tag_after == ""),
          temp_dir_removed:$dir_gone,
          qa_container_and_volume_removed:($c == 0 and $v == 0),
          baseline_and_candidate_tags_untouched:($base0 == $base1 and $cand0 == $cand1 and ($base0 | length) > 0)
        } } | .passed = (.assertions | all)' >>"$results"
  local extra
  extra=$(jq -n -c --argjson adv "$ADVERSARIAL_COMMON" '{adversarial:($adv + {mutation_testing:{probed:true, finding:"the same x11vnc recovery case that passes on the candidate FAILS on a mutant without the vnc/web relaunch branch (full-restart escalation: RestartCount +1, other layers replaced, 2 budget entries), so the harness can fail"}})}')
  emit_receipt task-2-mutation "bash scripts/qa-runtime.sh mutation" task-2-mutation.json "$results" "$extra"
}

############################ todo 2 part C: probe-selftest ############################

# Fake RFB listeners run INSIDE the QA container on a spare loopback port (never published, never production);
# the real probe script is pointed at them through its KAKAO_VNC_PORT override.
write_probe_selftest_py() { # <file>
  cat >"$1" <<'EOPY'
import json, os, socket, subprocess, threading, time
PORT = 5901
HC = "/usr/local/bin/kakao-healthcheck"

def serve(payload, hold):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT))
    s.listen(1)
    def run():
        try:
            c, _ = s.accept()
            if payload:
                c.sendall(payload)
            if hold:
                time.sleep(4.5)
            c.close()
        except Exception:
            pass
        finally:
            s.close()
    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t

def probe(port):
    env = dict(os.environ, KAKAO_VNC_PORT=str(port))
    t0 = time.time()
    p = subprocess.run([HC], env=env, capture_output=True, text=True, timeout=30)
    lines = p.stdout.strip().splitlines()
    return {"rc": p.returncode, "record": lines[0] if lines else "", "elapsed_s": round(time.time() - t0, 2), "stdout_lines": len(lines)}

variants = [
    ("short_banner_then_eof", b"RFB 003.", False, "fake"),
    ("short_banner_then_hold", b"RFB 003.", True, "fake"),
    ("empty_then_eof", b"", False, "fake"),
    ("twelve_bytes_not_rfb", b"HTTP/1.1 200", False, "fake"),
    ("full_banner_then_eof", b"RFB 003.008\n", False, "fake"),
    ("full_banner_then_hold", b"RFB 003.008\n", True, "fake"),
    ("real_vnc_port_5900", None, False, "real"),
]
out = []
for name, payload, hold, kind in variants:
    t = None
    if kind == "fake":
        t = serve(payload, hold)
        r = probe(PORT)
        t.join(timeout=10)
    else:
        r = probe(5900)
    r.update({"variant": name, "listener": kind, "sent_bytes": (len(payload) if payload is not None else None), "held_open": hold})
    out.append(r)
print(json.dumps(out))
EOPY
}

run_probe_selftest_case() { # prints the case JSON (runs in a subshell)
  local name=probe_selftest started; started=$(now_utc)
  log "probe-selftest: fresh volume, candidate image, wait ready"
  if ! stack_fresh_ready; then case_error "$name" "precondition: $READY_REASON"; return 0; fi
  local py="$WORK/probe_selftest.py" raw hc_in hc_wt pre
  write_probe_selftest_py "$py"
  pre=$(probe_json)
  raw=$(qa_mutate timeout 150 docker exec -i "$QA_CONTAINER" python3 - <"$py" 2>/dev/null)
  printf '%s' "$raw" | jq -e 'type == "array" and length == 7' >/dev/null 2>&1 || { case_error "$name" "fake-listener run returned no result"; return 0; }
  hc_in=$(timeout 20 docker exec "$QA_CONTAINER" sha256sum "$HC_IN_CONTAINER" 2>/dev/null | cut -d' ' -f1)
  hc_wt=$(sha_of "$REPO_ROOT/docker/healthcheck.sh")
  jq -n -c --arg name "$name" --arg started "$started" --arg finished "$(now_utc)" --argjson raw "$raw" --argjson pre "$pre" \
    --arg hcin "$hc_in" --arg hcwt "$hc_wt" '
    def parse: (.record | split(" ") | map(select(contains("=")) | split("=") | {(.[0]): (.[1:] | join("="))}) | add // {});
    ($raw | map(. + {parsed: parse})) as $v
    | def pick($n): ($v | map(select(.variant == $n)) | first);
    def nonready($n; $why): (pick($n) | .rc == 1 and .parsed.phase != "ready" and .parsed.layer == "vnc" and .parsed.reason == $why and .stdout_lines == 1);
    def ready($n): (pick($n) | .rc == 0 and .parsed.phase == "ready" and .parsed.layer == "app" and .parsed.reason == "ok" and .stdout_lines == 1);
    { case:$name, started_at:$started, finished_at:$finished,
      fault:{kind:"incomplete / foreign RFB banner on the probed VNC port", injection:"python listener inside the QA container on 127.0.0.1:5901, probe run with KAKAO_VNC_PORT=5901 (override of the probe only)", port:5901},
      probe_before:$pre, variants:$v, healthcheck_sha256:{in_container:$hcin, worktree:$hcwt},
      assertions:{
        short_banner_then_eof_is_vnc_not_ready: nonready("short_banner_then_eof"; "vnc_short_banner"),
        short_banner_then_hold_is_vnc_not_ready: nonready("short_banner_then_hold"; "vnc_short_banner"),
        empty_then_eof_is_vnc_not_ready: nonready("empty_then_eof"; "vnc_short_banner"),
        twelve_bytes_not_rfb_is_vnc_not_ready: nonready("twelve_bytes_not_rfb"; "vnc_bad_banner"),
        full_banner_then_eof_is_ready: ready("full_banner_then_eof"),
        full_banner_then_hold_is_ready: ready("full_banner_then_hold"),
        real_vnc_banner_is_ready: ready("real_vnc_port_5900"),
        every_probe_within_12s: ($v | all(.[]; .elapsed_s <= 12)),
        container_probe_was_ready_before: ($pre.phase == "ready"),
        container_runs_worktree_healthcheck: ($hcin != "" and $hcin == $hcwt)
      } } | .passed = (.assertions | all)'
}

cmd_probe_selftest() {
  need_tools; resolve_guard; use_candidate
  R_STARTED=$(now_utc); R_PB=$(prod_snapshot); R_WB=$(worktree_state)
  ensure_candidate
  SRC_JSON=$(source_light)
  local results="$WORK/probe.cases.jsonl" f="$WORK/probe.case.json" rc; : >"$results"
  ( run_probe_selftest_case ) >"$f"; rc=$?
  if ! jq -e . "$f" >/dev/null 2>&1; then case_error probe_selftest "case aborted without result (subshell exit $rc)" >"$f"; fi
  jq -c . "$f" >>"$results"
  local extra
  extra=$(jq -n -c --argjson adv "$ADVERSARIAL_COMMON" '{adversarial:($adv + {misleading_success_output:{probed:true, finding:"a banner only counts when read -N 12 succeeded with exactly 12 bytes starting RFB 003.; the 8-byte prefix followed by EOF or by a hold-open listener is vnc_short_banner (non-ready), a full banner stays ready"}})}')
  emit_receipt task-2-probe "bash scripts/qa-runtime.sh probe-selftest" task-2-probe.json "$results" "$extra"
}

############################ todo 2 part C: boot-deadline ############################

BOOT_DEADLINE_S=90
BOOT_HANG_WINEBOOT_TIMEOUT=600   # the step's OWN cap is far above the shared deadline, so only the shared deadline can end the boot
BOOT_CLEANUP_MAX=20
BOOT_EXIT_MIN=$((BOOT_DEADLINE_S - 5))
BOOT_EXIT_MAX=$((BOOT_DEADLINE_S + BOOT_CLEANUP_MAX + 10))   # deadline + bounded cleanup + docker start/stop slack
BOOT_BLOCK_DEADLINE="${QA_BOOT_BLOCK_DEADLINE:-480}"
BOOT_OBSERVE="${QA_BOOT_OBSERVE:-30}"

BOOT_EVENTS_FILE=""; BOOT_CID=""
boot_events() { # -> JSON [{action,t_ns,exit_code}] of THIS container id from the live `docker events` capture (the daemon ring buffer is too short for 5 min on a busy host)
  [ -f "$BOOT_EVENTS_FILE" ] || { printf '[]'; return 0; }
  jq -R -s -c --arg cid "$BOOT_CID" 'split("\n") | map(select(length > 0) | fromjson?) | map(select((.Action == "start" or .Action == "die") and .Actor.ID == $cid) | {action:.Action, t_ns:.timeNano, exit_code:(.Actor.Attributes.exitCode // null)})' "$BOOT_EVENTS_FILE"
}

# QA-only injection: a `wineboot` that never finishes and ignores SIGTERM is docker-cp'd into the created (not yet started) QA container
# at /usr/local/bin/wineboot (ahead of /usr/bin/wineboot in PATH). No production code path is patched.
boot_hang_up() {
  local d="$WORK/hang" cid; mkdir -p "$d"
  printf '%s\n' '#!/bin/bash' '# QA-only injection: wineboot that never finishes and ignores TERM (only timeout -k KILL ends it)' "trap '' TERM" 'exec sleep 3600' >"$d/wineboot"
  chmod 0755 "$d/wineboot"
  qa_mutate timeout 120 docker compose -p "$QA_PROJECT" -f "$COMPOSE_FILE" create --no-build --pull never >&2 || return 1
  cid=$(docker inspect --type container "$QA_CONTAINER" --format '{{.Id}}' 2>/dev/null) || return 1
  [ "$(qa_label_project container "$QA_CONTAINER")" = "$QA_PROJECT" ] || return 1
  tar -C "$d" --mode=0755 --owner=0 --group=0 -cf - wineboot | qa_mutate timeout 30 docker cp - "$cid:/usr/local/bin" >&2 || return 1
  qa_mutate timeout 60 docker start "$cid" >&2
}

run_boot_deadline_case() { # prints the case JSON (runs in a subshell)
  local name=boot_deadline started since cid
  started=$(now_utc)
  log "boot-deadline: fresh volume, hanging wineboot shim, KAKAO_WINEBOOT_TIMEOUT=$BOOT_HANG_WINEBOOT_TIMEOUT, expected exit at ~${BOOT_DEADLINE_S}s"
  STALE_CLEANED=false; prep_fresh
  export QA_WINEBOOT_TIMEOUT="$BOOT_HANG_WINEBOOT_TIMEOUT"
  since=$(( $(date +%s) - 2 ))
  BOOT_EVENTS_FILE="$WORK/boot.events"; : >"$BOOT_EVENTS_FILE"
  timeout 1500 docker events --since "$since" --filter "container=$QA_CONTAINER" --filter event=start --filter event=die --format '{{json .}}' >"$BOOT_EVENTS_FILE" 2>/dev/null &
  local EV_PID=$! clk_w0 clk_u0 clk_w1 clk_u1 skew
  clk_w0=$(date +%s.%N); clk_u0=$(cut -d' ' -f1 /proc/uptime)
  boot_hang_up || { case_error "$name" "create/inject/start failed"; return 0; }
  cid=$(docker inspect "$QA_CONTAINER" --format '{{.Id}}' 2>/dev/null); BOOT_CID=$cid
  { [ -n "$cid" ] && [ "$(qa_label_project container "$QA_CONTAINER")" = "$QA_PROJECT" ]; } || { case_error "$name" "QA container missing or without QA label"; return 0; }
  local T0=$SECONDS blocked=false blk_s=null st=null
  while :; do
    st=$(runtime_state_json)
    if printf '%s' "$st" | jq -e '.state.phase == "blocked" and .state.blocked == "1"' >/dev/null 2>&1; then blocked=true; blk_s=$((SECONDS - T0)); break; fi
    [ $((SECONDS - T0)) -ge "$BOOT_BLOCK_DEADLINE" ] && break
    sleep "$POLL_INTERVAL"
  done
  log "boot-deadline: blocked=$blocked after ${blk_s}s"
  local line rc0 started0 ev0 probe
  line=$(container_inspect_line "$QA_CONTAINER"); set -- $line; rc0=${2:--1}; started0=${3:-}
  ev0=$(boot_events); probe=$(probe_json)
  local samples="$WORK/samples.boot.jsonl" w0=$SECONDS l o_st o_rc o_started stable=true
  : >"$samples"
  if [ "$blocked" = true ]; then
    while :; do
      l=$(container_inspect_line "$QA_CONTAINER"); set -- $l; o_st=${1:-gone}; o_rc=${2:--1}; o_started=${3:-}
      jq -n -c --argjson t "$((SECONDS - w0))" --arg st "$o_st" --argjson rc "$o_rc" --arg started "$o_started" '{t_s:$t, container_status:$st, restart_count:$rc, started_at:$started}' >>"$samples"
      { [ "$o_st" = running ] && [ "$o_rc" = "$rc0" ] && [ "$o_started" = "$started0" ]; } || stable=false
      [ $((SECONDS - w0)) -ge "$BOOT_OBSERVE" ] && break
      sleep 5
    done
  fi
  local obs_s=$((SECONDS - w0)) ev1 fstate flogs banner dlrec envs pids rc1 started1 health shim_in shim_wt
  kill "$EV_PID" 2>/dev/null; wait "$EV_PID" 2>/dev/null
  clk_w1=$(date +%s.%N); clk_u1=$(cut -d' ' -f1 /proc/uptime)
  skew=$(python3 -c "print(round(max(1.0, ($clk_w1 - $clk_w0) / ($clk_u1 - $clk_u0)), 4))")
  ev1=$(boot_events)
  fstate=$(runtime_state_json); [ -n "$fstate" ] || fstate=null
  flogs=$(runtime_log_lines); [ -n "$flogs" ] || flogs='[]'
  banner=$(timeout 30 docker logs "$QA_CONTAINER" 2>&1 | grep -a -c 'KakaoTalk Web is up') || true
  dlrec=$(timeout 30 docker logs "$QA_CONTAINER" 2>&1 | grep -a -c 'reason=boot_deadline_exceeded .*action=exit code=13') || true
  envs=$(kakao_env_overrides); [ -n "$envs" ] || envs='["unreadable"]'
  pids=$(pidmap "$(proc_survey "$QA_CONTAINER")")
  line=$(container_inspect_line "$QA_CONTAINER"); set -- $line; rc1=${2:--1}; started1=${3:-}
  health=$(health_status)
  shim_in=$(timeout 20 docker exec "$QA_CONTAINER" sha256sum /usr/local/bin/wineboot 2>/dev/null | cut -d' ' -f1)
  shim_wt=$(sha_of "$WORK/hang/wineboot")
  jq -n -c --arg name "$name" --arg started "$started" --arg finished "$(now_utc)" --argjson blocked "$blocked" --argjson blk_s "$blk_s" \
    --argjson rc0 "$rc0" --argjson rc1 "${rc1:--1}" --arg started0 "$started0" --arg started1 "$started1" --argjson ev0 "$ev0" --argjson ev1 "$ev1" \
    --argjson probe "$probe" --argjson obs_s "$obs_s" --argjson want_obs "$BOOT_OBSERVE" --argjson stable "$stable" --slurpfile samples "$samples" \
    --argjson fstate "$fstate" --argjson flogs "$flogs" --argjson banner "${banner:-0}" --argjson dlrec "${dlrec:-0}" --argjson envs "$envs" \
    --argjson pids "$pids" --arg health "$health" --arg cid "$cid" --arg shim_in "$shim_in" --arg shim_wt "$shim_wt" \
    --argjson dl "$BOOT_DEADLINE_S" --argjson emin "$BOOT_EXIT_MIN" --argjson emax "$BOOT_EXIT_MAX" --arg owncap "$BOOT_HANG_WINEBOOT_TIMEOUT" --argjson skew "$skew" '
    ($fstate.state // {}) as $s | ($fstate.budget_entries // []) as $bud | ($s.budget_max // "3" | tonumber) as $max
    | ($ev1 | map(select(.action == "die"))) as $dies | ($ev1 | map(select(.action == "start"))) as $starts
    | [range(0; ($dies | length)) as $i | (($dies[$i].t_ns - $starts[$i].t_ns) / 1e9 / $skew | floor)] as $dur
    | [$flogs[] | select(contains("event=boot_deadline")) | capture("elapsed_s=(?<e>[0-9]+)").e | tonumber] as $elapsed
    | { case:$name, clock:{wall_over_monotonic_ratio:$skew, note:"the entrypoint deadline runs on the monotonic uptime clock; docker event timestamps are wall time, so boot_durations_s divides them by the wall/monotonic ratio measured over this case (1.0 = no skew)"}, started_at:$started, finished_at:$finished,
        fault:{kind:"boot step hangs", injection:("QA-only wineboot shim (ignores TERM, sleeps) docker-cp ed into the created container + KAKAO_WINEBOOT_TIMEOUT=" + $owncap + " via docker-compose.qa.yml QA_WINEBOOT_TIMEOUT"),
               mechanism:"the shared boot deadline (default 90s) caps the wineboot step to the remaining time -> run_bg expires -> boot_fail(boot_deadline_exceeded) -> exit 13 through fail_boot (budget-checked)", expected_exit_code:13, deadline_s:$dl},
        seconds_to_blocked:$blk_s, container_events:$ev1, boot_durations_s:$dur, logged_elapsed_s:$elapsed, probe_when_blocked:$probe,
        container:{id:$cid, restart_count_when_blocked:$rc0, restart_count_after_window:$rc1, started_at_when_blocked:$started0, started_at_after_window:$started1, docker_health:$health},
        observation:{window_s:$obs_s, requested_s:$want_obs, samples:$samples},
        runtime_state_after:$fstate, runtime_log_lines:$flogs, pids_after:$pids,
        counts:{deadline_exit_records:$dlrec, up_banner_lines:$banner}, kakao_env_overrides:$envs,
        shim_sha256:{in_container:$shim_in, harness_copy:$shim_wt},
        assertions:{
          injection_is_qa_only_hang_plus_env:($envs == ["KAKAO_WINEBOOT_TIMEOUT=" + $owncap] and $shim_in != "" and $shim_in == $shim_wt and ($owncap | tonumber) > $dl),
          first_boot_exits_at_deadline_plus_cleanup:(($dur | length) >= 1 and $dur[0] >= $emin and $dur[0] <= $emax),
          every_boot_exits_within_deadline_plus_cleanup:(($dur | length) == $max and ($dur | all(.[]; . >= $emin and . <= $emax))),
          logged_elapsed_at_deadline:(($elapsed | length) == $max and ($elapsed | all(.[]; . >= $dl and . <= $dl + 5))),
          every_boot_exit_nonzero_code_13:(($dies | length) == $max and ($dies | all(.[]; .exit_code == "13"))),
          wine_initialized_marker_not_created:($s != {} and $fstate.wine_initialized_marker == "absent"),
          budget_consumed_by_each_deadline_boot:(($bud | length) == $max and ($bud | all(.[]; test(" boot_failure boot_deadline_exceeded$")))),
          exits_equal_budget_and_restart_count:($rc1 == $max and ($dies | length) == $max),
          failure_records_logged_per_boot:($dlrec == $max),
          diagnostics_in_failure_log:(($fstate.failure_log_tail // []) | any(.[]; contains("event=boot_deadline step=")) and any(.[]; contains("reason=boot_deadline_exceeded"))),
          eventually_blocked:($blocked and $s.phase == "blocked" and $s.blocked == "1" and $s.reason == "budget_exhausted_at_boot" and $probe.phase == "blocked"),
          no_boot_loop_after_block:($stable and $obs_s >= $want_obs and ($ev1 | length) == ($ev0 | length) and $rc1 == $rc0 and $started0 == $started1),
          kakaotalk_never_launched:(($pids.app | length) == 0 and $banner == 0)
        } } | .passed = (.assertions | all)'
}

cmd_boot_deadline() {
  need_tools; resolve_guard; use_candidate
  R_STARTED=$(now_utc); R_PB=$(prod_snapshot); R_WB=$(worktree_state)
  ensure_candidate
  SRC_JSON=$(source_light)
  local results="$WORK/boot.cases.jsonl" f="$WORK/boot.case.json" rc; : >"$results"
  ( run_boot_deadline_case ) >"$f"; rc=$?
  if ! jq -e . "$f" >/dev/null 2>&1; then case_error boot_deadline "case aborted without result (subshell exit $rc)" >"$f"; fi
  jq -c . "$f" >>"$results"
  local extra
  extra=$(jq -n -c --argjson adv "$ADVERSARIAL_COMMON" '{adversarial:($adv + {hung_commands:{probed:true, finding:"a wineboot that ignores SIGTERM and never exits ends the boot at the shared 90s deadline (+2s KILL grace, +bounded cleanup), not at its own 600s cap; boot loops of such failures still end in phase=blocked after 3 budgeted boots"}})}')
  emit_receipt task-2-boot-deadline "bash scripts/qa-runtime.sh boot-deadline" task-2-boot-deadline.json "$results" "$extra"
}

############################ ui-survey: which KakaoTalk window does a fresh volume show? ############################

shot_root() { # <dest.png>: X root screenshot taken INSIDE the QA container (PIL ImageGrab on the Xvfb display), copied out
  local disp; disp=$(timeout 20 docker exec "$QA_CONTAINER" sh -c 'ls /tmp/.X11-unix | head -n 1 | tr -d X' 2>/dev/null | tr -d ' \r\n')
  mkdir -p "$(dirname "$1")" || return 1
  timeout 30 docker exec "$QA_CONTAINER" python3 -c "
from PIL import ImageGrab
ImageGrab.grab(xdisplay=':${disp:-100}').save('/tmp/qa-root.png')" >/dev/null 2>&1 \
    && timeout 30 docker cp "$QA_CONTAINER:/tmp/qa-root.png" "$1" >/dev/null 2>&1
}

# ui-survey [candidate|baseline]: fresh QA volume, NO fault injected. baseline = the production scripts of git HEAD (91cff7e,
# hash-pinned) docker-cp'd into the baseline image (production-equivalent); candidate = the worktree scripts in the candidate image.
# Records the geometry of every kakaotalk.exe window (no titles), whether a login-sized window appears, and an X root screenshot.
cmd_ui_survey() {
  need_tools; resolve_guard
  local mode=${1:-candidate} started; started=$(now_utc)
  case "$mode" in
    candidate) use_candidate; ensure_candidate ;;
    baseline)
      QA_IMAGE=$BASELINE_TAG; export QA_IMAGE
      QA_SCRIPTS_MODE=production-runtime
      RUNTIME_SRC_DIR="$WORK/head-docker"; mkdir -p "$RUNTIME_SRC_DIR"
      git -C "$REPO_ROOT" show HEAD:docker/entrypoint.sh >"$RUNTIME_SRC_DIR/entrypoint.sh" || die_env "cannot read HEAD entrypoint"
      git -C "$REPO_ROOT" show HEAD:docker/run-kakao.sh >"$RUNTIME_SRC_DIR/run-kakao.sh" || die_env "cannot read HEAD runner" ;;
    *) log "usage: ui-survey [candidate|baseline]"; exit "$EX_USAGE" ;;
  esac
  local pb; pb=$(prod_snapshot)
  STALE_CLEANED=false
  prep_fresh
  qa_up || die_env "compose up failed"
  wait_ready || die_env "$READY_REASON"
  local dl=$((SECONDS + ${QA_UI_SURVEY_DEADLINE:-120})) win net shot rel
  while :; do
    win=$(kakao_windows)
    printf '%s' "$win" | jq -e '.login_ui_present == true' >/dev/null 2>&1 && break
    [ "$SECONDS" -ge "$dl" ] && break
    sleep "$POLL_INTERVAL"
  done
  net=$(timeout 15 docker exec "$QA_CONTAINER" sh -c 'timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>/dev/null && echo reachable || echo unreachable' 2>/dev/null | tr -d '\r\n')
  rel="ui-survey/root-$mode.png"; shot="$(evidence_dir)/$rel"
  shot_root "$shot" || { log "screenshot failed"; shot=""; }
  local logs; logs=$(runtime_log_lines); [ -n "$logs" ] || logs='[]'
  local json
  json=$(jq -n -c --arg mode "$mode" --arg started "$started" --arg finished "$(now_utc)" --argjson win "$win" --arg net "${net:-unknown}" \
    --arg shot "${shot:+$rel}" --argjson logs "$logs" --arg qai "$QA_IMAGE" --argjson pb "$pb" --argjson pa "$(prod_snapshot)" \
    --argjson sha "$(jq -n -c --arg e "$(sha_of "${RUNTIME_SRC_DIR:-$REPO_ROOT/docker}/entrypoint.sh")" --arg r "$(sha_of "${RUNTIME_SRC_DIR:-$REPO_ROOT/docker}/run-kakao.sh")" '{entrypoint:$e,runner:$r}')" \
    '{task:("task-2-ui-survey-" + $mode), schema:1, mode:$mode, image:$qai, scripts_sha256:$sha, started_at:$started, finished_at:$finished,
      fault_injected:false, windows:$win, login_ui_present:$win.login_ui_present, only_dialog_sized_windows:$win.only_dialog_sized,
      outbound_tcp_443:$net, screenshot:(if $shot == "" then null else $shot end), runtime_log_lines:$logs,
      production_unchanged:(($pb.found // false) and ($pa.found // false) and $pb.id == $pa.id and $pb.started_at == $pa.started_at and $pb.restart_count == $pa.restart_count and $pb.status == $pa.status)}')
  write_evidence "task-2-ui-survey-$mode.json" "$json"
  printf '%s\n' "$json" | jq '{mode, login_ui_present, windows:.windows.kakaotalk_geometries, outbound_tcp_443, screenshot}'
}

############################ todo 3: operations (scripts/kakaoctl.sh) ############################

KCTL="$REPO_ROOT/scripts/kakaoctl.sh"
CTL_RC=0

ops_has() { grep -qE -- "$2" "$1"; } # <file> <ERE>
ops_chk() { # <name> <1|0> <detail>
  jq -n -c --arg n "$1" --argjson p "$([ "$2" = 1 ] && echo true || echo false)" --arg d "$3" '{name:$n, passed:$p, detail:$d}' >>"$WORK/ops.checks.jsonl"
  log "check $1: $([ "$2" = 1 ] && echo PASS || echo FAIL) - $3"
}
ops_ctl() { # <outfile> <kakaoctl args...>: stdout+stderr to the file, exit code in CTL_RC
  local out=$1; shift
  timeout 240 bash "$KCTL" "$@" >"$out" 2>&1; CTL_RC=$?
}
ops_started_at() { docker inspect "$QA_CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null; }
ops_marker_present() { timeout 20 docker exec "$QA_CONTAINER" test -e /data/runtime-state/manual-recovery 2>/dev/null; }

# Proves status/diagnose/restart on the QA stack only. Production is never a restart target; it is only the
# (refused) wrong target of a read-only status call. The QA VNC_PASSWORD is a random sentinel supplied through a
# temp compose override (only its hash/length is recorded) and must not appear in any kakaoctl output.
cmd_operations() {
  need_tools
  local started; started=$(now_utc)
  local o="$WORK/ops"; mkdir -p "$o"
  local f; for f in status diagnose restart status_after snapshot; do : >"$o/$f.txt"; done
  : >"$WORK/ops.checks.jsonl"
  local sentinel; sentinel="QA-SENTINEL-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  local sent_sha; sent_sha=$(printf '%s' "$sentinel" | sha256sum | cut -d' ' -f1)
  local ov="$WORK/override.qa.yml"
  ( umask 077; printf 'services:\n  kakaotalk:\n    environment:\n      VNC_PASSWORD: "%s"\n' "$sentinel" >"$ov" )
  QA_COMPOSE_OVERRIDE=$ov; export QA_COMPOSE_OVERRIDE
  resolve_guard; use_candidate
  local pb; pb=$(prod_snapshot)
  ensure_candidate
  SRC_JSON=$(source_light)
  local reason=""
  stack_fresh_ready || reason="$READY_REASON"
  if [ -z "$reason" ]; then
    local in_sha img_now st0 st1 now dl p_val init0 init1 p_after started_before sj occ shim real rc_r rc_i rc_bogus rc_restart ready_after=0
    in_sha=$(timeout 20 docker exec "$QA_CONTAINER" sh -c 'printf %s "$VNC_PASSWORD"' 2>/dev/null | sha256sum | cut -d' ' -f1)
    ops_chk sentinel_reached_container "$(if [ "$in_sha" = "$sent_sha" ]; then echo 1; else echo 0; fi)" "container VNC_PASSWORD hash equals the sentinel hash (value never printed)"
    img_now=$(docker inspect "$QA_CONTAINER" --format '{{.Image}}' 2>/dev/null)

    # 1. status: correct target, docker facts, image ID, probe + runtime phases
    ops_ctl "$o/status.txt" status --project "$QA_PROJECT" --container "$QA_CONTAINER"
    ops_chk status_output "$(if [ "$CTL_RC" = 0 ] && ops_has "$o/status.txt" "^target:   project=$QA_PROJECT container=$QA_CONTAINER\$" \
        && ops_has "$o/status.txt" '^docker:   status=running health=[a-z]+ restart_count=0 ' && ops_has "$o/status.txt" "^image:    id=$img_now " \
        && ops_has "$o/status.txt" '^probe:    phase=ready layer=app reason=ok ' && ops_has "$o/status.txt" '^runtime:  phase=ready ' \
        && ops_has "$o/status.txt" '^budget:   used_in_window=0/3$'; then echo 1; else echo 0; fi)" "exit=$CTL_RC; target, docker state, image ID, probe phase=ready, runtime phase=ready, budget 0/3"

    # 2. diagnose: status + processes + failure log + runtime log lines
    ops_ctl "$o/diagnose.txt" diagnose --project "$QA_PROJECT" --container "$QA_CONTAINER"
    ops_chk diagnose_output "$(if [ "$CTL_RC" = 0 ] && ops_has "$o/diagnose.txt" "^target:   project=$QA_PROJECT container=$QA_CONTAINER\$" \
        && ops_has "$o/diagnose.txt" '^probe:    phase=ready ' && ops_has "$o/diagnose.txt" '^--- processes' && ops_has "$o/diagnose.txt" ' Xvfb$' \
        && ops_has "$o/diagnose.txt" ' x11vnc$' && ops_has "$o/diagnose.txt" ' KakaoTalk.exe$' && ops_has "$o/diagnose.txt" '^--- last-failure.log' \
        && ops_has "$o/diagnose.txt" '^--- recent \[kakao-runtime\]' && ops_has "$o/diagnose.txt" '^\[kakao-runtime\] '; then echo 1; else echo 0; fi)" "exit=$CTL_RC; sections, process names and runtime log lines present"

    # 3. wrong targets are refused (exit 3) with no side effect
    started_before=$(ops_started_at)
    ops_ctl "$o/w1.txt" status --project kakaotalk-web --container "$QA_CONTAINER"
    ops_chk wrong_project_status_refused "$(if [ "$CTL_RC" = 3 ] && ops_has "$o/w1.txt" 'REFUSED' && ! ops_has "$o/w1.txt" '== kakaoctl'; then echo 1; else echo 0; fi)" "exit=$CTL_RC (QA container with the production project name)"
    ops_ctl "$o/w2.txt" restart --project kakaotalk-web --container "$QA_CONTAINER"
    ops_chk wrong_project_restart_refused "$(if [ "$CTL_RC" = 3 ] && ops_has "$o/w2.txt" 'REFUSED' && [ "$(ops_started_at)" = "$started_before" ] && ! ops_marker_present; then echo 1; else echo 0; fi)" "exit=$CTL_RC; QA container StartedAt unchanged, no marker created"
    ops_ctl "$o/w3.txt" status --project "$QA_PROJECT" --container "$PROD_CONTAINER"
    ops_chk production_with_qa_project_refused "$(if [ "$CTL_RC" = 3 ] && ops_has "$o/w3.txt" 'REFUSED'; then echo 1; else echo 0; fi)" "exit=$CTL_RC (read-only status of the production container with the QA project name)"
    ops_ctl "$o/w4.txt" status --container qa-no-such-container-xyz
    ops_chk missing_container_refused "$(if [ "$CTL_RC" = 3 ] && ops_has "$o/w4.txt" 'does not exist'; then echo 1; else echo 0; fi)" "exit=$CTL_RC"
    ops_ctl "$o/w5.txt" bogus; rc_bogus=$CTL_RC
    ops_ctl "$o/w6.txt" status --container 'bad name'
    ops_chk usage_errors_64 "$(if [ "$rc_bogus" = 64 ] && [ "$CTL_RC" = 64 ]; then echo 1; else echo 0; fi)" "unknown command exit=$rc_bogus; invalid container name exit=$CTL_RC"

    # 4. inject two budget entries (QA container only) and wait until the monitor reports them
    now=$(date +%s)
    timeout 20 docker exec "$QA_CONTAINER" sh -c 'printf "%s qa_injected ops_test_1\n%s qa_injected ops_test_2\n" "$1" "$1" >>/data/runtime-state/budget.log' _ "$now"
    dl=$((SECONDS + 60))
    until [ "$(runtime_state_json | jq -r '.state.recovery_count // ""')" = 2 ]; do [ "$SECONDS" -ge "$dl" ] && break; sleep 3; done
    ops_ctl "$o/status_used.txt" status --project "$QA_PROJECT" --container "$QA_CONTAINER"
    ops_chk status_shows_used_budget "$(if [ "$CTL_RC" = 0 ] && ops_has "$o/status_used.txt" '^budget:   used_in_window=2/3$' && ops_has "$o/status_used.txt" 'qa_injected ops_test_1' && ops_has "$o/status_used.txt" '^monitor:  recovery_count=2/3 '; then echo 1; else echo 0; fi)" "exit=$CTL_RC; budget used_in_window=2/3 and monitor recovery_count=2/3"

    # 5. persistence sentinels before restart
    p_val="qa-persist-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    timeout 20 docker exec "$QA_CONTAINER" sh -c 'printf %s "$1" >/data/qa-persistence-sentinel' _ "$p_val"
    init0=$(timeout 20 docker exec "$QA_CONTAINER" sh -c 'stat -c "%Y %s" /data/wineprefix/.initialized 2>/dev/null || echo absent')
    st0=$(ops_started_at)

    # 6. docker command failures propagate their exit code (PATH shim in front of docker: restart -> 17, inspect -> 23)
    shim="$WORK/shim"; real=$(command -v docker); mkdir -p "$shim"
    printf '#!/bin/sh\nif [ "$1" = "$SHIM_FAIL" ]; then\n  case "$1" in\n    restart) echo "shim: simulated docker restart failure" >&2; exit 17 ;;\n    inspect) echo "shim: simulated docker daemon failure" >&2; exit 23 ;;\n  esac\nfi\nexec "%s" "$@"\n' "$real" >"$shim/docker"
    chmod +x "$shim/docker"
    SHIM_FAIL=restart PATH="$shim:$PATH" timeout 240 bash "$KCTL" restart --project "$QA_PROJECT" --container "$QA_CONTAINER" >"$o/fail_restart.txt" 2>&1; rc_r=$?
    ops_chk failed_restart_exit_code_propagated "$(if [ "$rc_r" = 17 ] && ops_has "$o/fail_restart.txt" 'docker restart failed \(exit 17\)' && [ "$(ops_started_at)" = "$st0" ] && ! ops_marker_present; then echo 1; else echo 0; fi)" "exit=$rc_r (expected 17); container not restarted, marker removed again"
    SHIM_FAIL=inspect PATH="$shim:$PATH" timeout 240 bash "$KCTL" status --project "$QA_PROJECT" --container "$QA_CONTAINER" >"$o/fail_inspect.txt" 2>&1; rc_i=$?
    ops_chk failed_inspect_exit_code_propagated "$(if [ "$rc_i" = 23 ]; then echo 1; else echo 0; fi)" "exit=$rc_i (expected 23)"

    # 7. real restart: snapshot + marker + docker restart; budget reset, data kept, container ready again
    ops_ctl "$o/restart.txt" restart --project "$QA_PROJECT" --container "$QA_CONTAINER"; rc_restart=$CTL_RC
    READY_TIMEOUT=240
    wait_runtime_ready && ready_after=1
    wait_monitor_ack 0 90 || true
    st1=$(ops_started_at)
    sj=$(runtime_state_json)
    timeout 20 docker exec "$QA_CONTAINER" cat /data/runtime-state/manual-restart.snapshot >"$o/snapshot.txt" 2>/dev/null
    p_after=$(timeout 20 docker exec "$QA_CONTAINER" cat /data/qa-persistence-sentinel 2>/dev/null)
    init1=$(timeout 20 docker exec "$QA_CONTAINER" sh -c 'stat -c "%Y %s" /data/wineprefix/.initialized 2>/dev/null || echo absent')
    ops_chk restart_exit_and_output "$(if [ "$rc_restart" = 0 ] && ops_has "$o/restart.txt" '^snapshot: ' && ops_has "$o/restart.txt" '^marker:   ' && ops_has "$o/restart.txt" '^restarted: '; then echo 1; else echo 0; fi)" "exit=$rc_restart; snapshot written, marker created, restarted"
    ops_chk restart_really_restarted "$(if [ "$st1" != "$st0" ]; then echo 1; else echo 0; fi)" "StartedAt $st0 -> $st1"
    ops_chk restart_snapshot_content "$(if ops_has "$o/snapshot.txt" '^# kakaoctl restart snapshot ts=' && ops_has "$o/snapshot.txt" '^budget:   used_in_window=2/3$' && ops_has "$o/snapshot.txt" '^runtime:  phase='; then echo 1; else echo 0; fi)" "snapshot taken before the restart shows budget 2/3"
    ops_chk restart_budget_reset "$(if printf '%s' "$sj" | jq -e '(.budget_entries | length) == 0 and (.state.recovery_count == "0") and (.state.last_budget_reset | test("manual_recovery")) and ((.failure_log_tail | map(select(test("event=budget_reset reason=manual_recovery cleared_entries=2"))) | length) >= 1)' >/dev/null; then echo 1; else echo 0; fi)" "budget.log empty, recovery_count 0, last_budget_reset manual_recovery, failure log records cleared_entries=2"
    ops_chk restart_marker_consumed "$(if ! ops_marker_present; then echo 1; else echo 0; fi)" "manual-recovery marker removed by the boot"
    ops_chk restart_ready_again "$(if [ "$ready_after" = 1 ]; then echo 1; else echo 0; fi)" "probe ready + HTTP 200 + WS RFB banner after the restart"
    ops_chk restart_data_preserved "$(if [ "$p_after" = "$p_val" ] && [ "$init0" = "$init1" ]; then echo 1; else echo 0; fi)" "persistence sentinel intact; .initialized stat unchanged ($init0)"
    ops_ctl "$o/status_after.txt" status --project "$QA_PROJECT" --container "$QA_CONTAINER"
    ops_chk status_after_restart "$(if [ "$CTL_RC" = 0 ] && ops_has "$o/status_after.txt" '^probe:    phase=ready ' && ops_has "$o/status_after.txt" '^budget:   used_in_window=0/3$'; then echo 1; else echo 0; fi)" "exit=$CTL_RC; ready, budget 0/3"

    # 8. the sentinel appears in no kakaoctl output nor in the snapshot; kakaoctl code never touches the environment
    occ=$(cat "$o"/*.txt | grep -c -F -- "$sentinel"); occ=${occ:-0}
    ops_chk secret_sentinel_absent "$(if [ "$occ" = 0 ]; then echo 1; else echo 0; fi)" "sentinel occurrences in all kakaoctl outputs + snapshot: $occ"
    ops_chk kakaoctl_source_no_env_access "$(if ! { grep -v '^[[:space:]]*#' "$KCTL" | grep -qE 'Config\.Env|printenv|\benv\b|VNC_PASSWORD|\.env'; } && bash -n "$KCTL"; then echo 1; else echo 0; fi)" "no env/Config.Env/VNC_PASSWORD references in code lines; bash -n ok"
    ops_chk kakaoctl_defaults "$(if grep -q '^PROJECT=kakaotalk-web$' "$KCTL" && grep -q '^CONTAINER=kakaotalk-wine$' "$KCTL"; then echo 1; else echo 0; fi)" "defaults kakaotalk-web / kakaotalk-wine"
    echo "$occ" >"$WORK/ops.occ"
  fi
  local occ_n; occ_n=$(cat "$WORK/ops.occ" 2>/dev/null || echo null)
  local pa; pa=$(prod_snapshot)
  local outs
  outs=$(jq -n -c --rawfile s "$o/status.txt" --rawfile d "$o/diagnose.txt" --rawfile r "$o/restart.txt" --rawfile a "$o/status_after.txt" --rawfile n "$o/snapshot.txt" \
    '{status:($s|split("\n")), diagnose:($d|split("\n")), restart:($r|split("\n")), status_after_restart:($a|split("\n")), restart_snapshot:($n|split("\n"))}')
  local json
  json=$(jq -n -c --arg started "$started" --arg finished "$(now_utc)" --argjson src "$SRC_JSON" --argjson checks "$(jq -s -c . "$WORK/ops.checks.jsonl")" \
    --arg reason "$reason" --arg qai "$QA_IMAGE" --arg imgid "$(img_id "$CANDIDATE_TAG")" --arg ssha "$sent_sha" --argjson slen "${#sentinel}" --argjson occ "$occ_n" \
    --argjson outs "$outs" --argjson pb "$pb" --argjson pa "$pa" '
    { task:"task-3-operations", schema:1, command:"bash scripts/qa-runtime.sh operations", started_at:$started, finished_at:$finished, source:$src,
      image:{qa_tag:$qai, id:$imgid}, setup_error:(if $reason == "" then null else $reason end),
      checks:$checks,
      secret_sentinel:{sha256:$ssha, length:$slen, occurrences_in_kakaoctl_outputs_and_snapshot:$occ,
                       note:"random per run, supplied as QA VNC_PASSWORD through a temp compose override; only its hash is recorded"},
      outputs:$outs,
      production:{before:$pb, after:$pa,
                  unchanged:(($pb.found // false) and ($pa.found // false) and $pb.id == $pa.id and $pb.started_at == $pa.started_at and $pb.restart_count == $pa.restart_count and $pb.status == $pa.status),
                  note:"production was only inspected; a change here (e.g. orchestrator redeploy) is noted, not a QA failure"},
      result:{checks_total:($checks|length), checks_passed:($checks|map(select(.passed))|length),
              passed:(($reason == "") and (($checks|length) > 0) and ($checks|all(.passed)))} }') || die_env "failed to assemble operations JSON"
  json=$(printf '%s' "$json" | jq -c '.exit_code = (if .result.passed then 0 else 2 end)')
  write_evidence task-3-operations.json "$json"
  printf '%s\n' "$json" | jq '{result, checks:[.checks[] | {name, passed}], production_unchanged:.production.unchanged}'
  [ "$(printf '%s' "$json" | jq -r '.result.passed')" = true ] || exit "$EX_ENV"
}

############################ dispatch ############################

SRC_JSON=null
case "${1:-}" in
  guard) cmd_guard ;;
  guard-selftest) cmd_guard_selftest ;;
  ui-survey) shift; cmd_ui_survey "$@" ;;
  up) cmd_up ;;
  baseline) cmd_baseline ;;
  build) cmd_build ;;
  healthy) cmd_healthy ;;
  recovery) shift; cmd_recovery "$@" ;;
  nonfaults) shift; cmd_nonfaults "$@" ;;
  circuit) shift; cmd_circuit "$@" ;;
  init-failure) cmd_init_failure ;;
  mutation) cmd_mutation ;;
  probe-selftest) cmd_probe_selftest ;;
  boot-deadline) cmd_boot_deadline ;;
  operations) cmd_operations ;;
  cleanup) cmd_cleanup "${2:-task-1}" ;;
  manifest) cmd_manifest ;;
  *)
    sed -n '2,53p' "$SCRIPT_PATH" >&2
    exit "$EX_USAGE"
    ;;
esac
