# kakaotalk-runtime-reliability - Work Plan

## TL;DR (For humans)
<!-- Fill this LAST, after the detailed plan below is written, so it summarizes the REAL plan. -->
<!-- Plain English for a non-engineer: NO file paths, NO todo numbers, NO wave/agent/tool names. -->

**Who this is for and what changes for them:** 윈도우에서 카톡을 직접 쓰지 못해 브라우저로 우회하는 사용자를 위한 계획이다. 기존 접속 주소와 로그인 데이터를 유지하면서 반복 수동 재기동을 줄인다.

**What you'll get:** 카톡·화면·웹 연결을 나눠 상태를 확인하고, 종료된 부분만 우선 복구한다. 반복 실패는 중단하고 원인을 남기며, 자동 판별이 어려운 멈춤은 진단 후 한 명령으로 재기동한다.

**Why this approach:** 웹 페이지가 열리는 것과 카톡이 동작하는 것은 다르다. 접속 방식을 바꾸는 대신 현재 구조의 감시 누락과 잘못된 종료 판정을 고치고, 작은 고장 때문에 전체 환경을 재시작하지 않게 한다.

**What it will NOT do:** 윈도우의 원래 카톡 문제나 카카오 서버 장애를 해결하는 계획은 아니다. 로그인 초기화·대화 전송·플랫폼 전환·무조건적인 반복 재기동은 하지 않으며, 운영 적용은 별도 승인 뒤 진행한다.

**Effort:** Medium
<!-- Effort is exactly ONE band, never hours/days. Quick = single edit, minutes of agent work; Short = one focused change, a few files; Medium = multi-file feature in one session; Large = several waves, one long session; XL = multi-session or architectural work. A written duration is rewritten to a band. -->
**Risk:** Medium - 실행 중인 카톡과 로그인 데이터가 있는 환경이므로 격리 장애 시험과 백업·롤백 확인이 필요하다.
**Decisions I made for you:** 추가 유료 서비스 없이 현재 호스트를 유지한다. 창 최소화는 고장으로 보지 않고, 자동 복구는 짧은 시간에 세 번까지만 허용한다. 모든 UI 멈춤을 자동 감지한다고 약속하지 않는다.

Your next move: 이 계획으로 별도 실행을 요청하면 구현과 격리 검증을 진행할 수 있다. 현재는 계획만 작성하며 커밋·배포 권한은 없다. Full execution detail follows below.

---

> TL;DR (machine): Medium / Medium / 기존 noVNC 유지, 계층별 상태와 제한된 복구, 진단·데이터 보존·롤백.

## Scope
### Affected user and ideal state
<!-- From the draft ledger: who this touches and how they use the result, then one IS row per property with its reason, then one GAP row per difference with its reason. Every todo below closes a GAP row; ## Success criteria proves every IS row. -->
**Affected user:** Windows 네이티브 카톡을 사용할 수 없어 localhost:14500의 브라우저로 카톡을 쓰는 본인. 선택한 방향은 기존 웹 접속 유지와 자동 복구 보강이다.

| Row | Statement | Reason |
| --- | --- | --- |
| IS-1 | 기존 URL에서 카톡 화면을 열고 한글을 입력할 수 있다 | 우회 환경의 본래 목적이며 HTTP 200만으로 대체할 수 없다 |
| IS-2 | 카톡 또는 필수 화면/접속 프로세스 종료를 감지하고 자동 복구한다 | 수동 컨테이너 재기동을 줄인다 |
| IS-3 | 최소화·로그인 대기를 장애로 오판하지 않고, 반복 고장은 제한하고 이유를 남긴다 | 재시작 폭주와 작업 방해를 막는다 |
| IS-4 | 재기동·배포·롤백에서 기존 Wine/로그인 데이터를 삭제하지 않는다 | 재설정과 데이터 손실을 막는다 |
| IS-5 | 자동 판별이 어려운 UI 멈춤에는 진단과 명시적 수동 복구 명령이 있다 | 프로세스 생존을 UI 응답 보장으로 오인하지 않는다 |
| GAP-1 | 작업 사본과 실제 실행 원본이 다르다 | 잘못된 사본을 고쳐도 현재 서비스에 반영되지 않는다 |
| GAP-2 | 실행 원본에 healthcheck가 없고 websockify만 기다린다 | 카톡/X/VNC 종료가 컨테이너 종료로 이어지지 않을 수 있다 |
| GAP-3 | 장애 직전 기록과 계층별 상태, 재시작 제한이 없다 | HTTP 정상과 실제 이용 불가를 구별하기 어렵다 |
| GAP-4 | 지속 볼륨은 있으나 검증된 복구·백업·롤백 절차가 없다 | 초기화나 무계획 업데이트를 복구로 사용하면 안 된다 |
| GAP-5 | 브라우저의 실제 카톡 이용 검증이 없다 | 창/입력/트레이 상태와 연결 실패를 구별해야 한다 |

### Must have
- 실제 구현 기준 저장소는 `/home/root1/kakaotalk-web`, 기준 revision `91cff7e`. 이 계획을 보관하는 `/home/root1/work/kakaotalk-web@d329c63`에서 제품 코드를 고치거나 두 사본을 통째로 동기화하지 않는다.
- 구성요소: C1 실제 원본/배포/롤백, C2 Wine·카톡·X 세션 생명주기, C3 VNC·웹 접속과 진단. 새로운 외부 서비스나 supervisor 패키지는 추가하지 않는다.
- 기본값: 1인 로컬 사용, 현재 호스트·포트·공유 폴더·기존 named volume 유지, 유료 서비스 없음. 기존 RDP 기능은 회귀 확인만 하며 주 접속은 웹이다.
- 확인 사실: 실행 이미지 `sha256:dcdc7a66f7ab925ca0d62c166b7407b9b1f635071d28aa92d59eb583e6bfc9a3`, `Healthcheck=null`, `restart=unless-stopped`. 원본과 실행 스크립트 해시 일치. 재기동 전 장애 원인은 미확정이다.
- 원본 entrypoint SHA256 `0ab63fb807bb3bb11112b8c61400926f1d88e75160f807bda23adaea2ba9c7e6`, runner SHA256 `3d907e76747210b99dfba610892827f9969fc89d6965a71925f21ce291543b5b`. 구현 시작 때 다시 확인하고 차이가 있으면 변경을 보존해 재평가한다.
### Must NOT have (guardrails, anti-slop, scope boundaries)
- Windows 네이티브 카톡 고장 조사, VM/새 호스트 전환, 자동 앱/Wine 업그레이드, 이미지 버전 임의 갱신, RDP 재설계, 인증/공개 포트 정책 변경은 하지 않는다.
- 운영 컨테이너를 장애 주입 대상으로 쓰지 않는다. `down -v`, volume 삭제/초기화, 로그인·자동로그인 설정 변경, 실제 메시지 전송, 다른 저장소 WIP 변경 금지.
- 창 없음·트레이 최소화·로그인 화면·네트워크 단절·프로세스 생존을 각각 구별한다. 일반적인 Wine UI hang이나 카카오 서버 장애의 자동 해결은 보장하지 않는다.

## Verification strategy
> Zero human intervention - all verification is agent-executed.
- Test decision: tests-after. 기존 전용 테스트 스위트 없음. 외부 프레임워크 없이 Bash 통합 QA 드라이버와 실제 Docker/noVNC 브라우저 확인을 추가한다. 문구/상수 고정 테스트는 만들지 않는다.
- 실행 증거 루트 `doc/evidence/kakaotalk-runtime-reliability/<tested-short-sha>/`; 미커밋이면 `git diff --binary`의 SHA256도 manifest에 기록해 소스 revision과 함께 결박한다. 이미지 ID·Docker/Compose 버전·실행 명령·exit code·정상/실패 상태·정리 결과를 저장한다. 계정/대화 내용은 저장하지 않는다.
- QA project `kakao-reliability-qa`, 서비스 `kakaotalk`, 컨테이너 `kakaotalk-reliability-qa`, 포트 `127.0.0.1:24500:14500`, `127.0.0.1:23389:3389`, QA 전용 volume. 이미지 태그 `kakaotalk-wine:reliability-qa`. 운영 이름/포트/volume/이미지 태그 재사용 금지.
- `docker compose -p kakao-reliability-qa -f docker-compose.qa.yml build` 및 `up -d` 후, Docker events와 제한시간을 둔 상태 관측으로 기대 상태 전이를 기다린다. 테스트의 고정 sleep, 타이밍 운에 의한 성공, 무한 대기 금지. 주기적 런타임 감시와 복구 시간 상한 시험은 시간 자체가 동작인 예외다.
- 기준 revision의 격리된 이미지에서 x11vnc 종료 후 웹 HTTP 200이 남지만 실제 연결 실패하는 대조 증거를 먼저 확보한다. 수정본에서 같은 장애가 복구되고 브라우저 RFB 연결·화면 입력이 돌아와야 PASS다.
- 실제 계정이 필요한 로그인/기존 데이터 QA는 승인된 운영 적용 창에서만 수행한다. 승인 전에는 격리 QA 통과로만 보고하며 운영 안정화 완료라고 하지 않는다. 실행 시작 자체는 배포/운영 중단 허가가 아니다.

## Execution strategy
### Parallel execution waves
> Group todos into a wave only when their write paths, state and proof are disjoint; serialize todos that overlap in write scope. One cohesive change is ONE todo and can be ONE worker - the todo count is not a goal.
Wave 1: todo 1 기준/격리 QA 계약 확정. Wave 2: todo 2 런타임+검증의 단일 소유 구현. Wave 3: todo 3 운영 절차/승인된 적용과 실제 화면 확인. 같은 entrypoint/runner와 실행 상태를 공유하므로 순차 실행한다.
마지막 F1~F4는 모든 구현/시나리오 증거가 준비된 뒤 읽기 전용으로 병렬 검토한다. F3는 기존 증거 재검토를 우선하고, 누락 재현은 하나의 QA 소유자만 수행한다.

### Dependency matrix
| Todo | Depends on | Blocks | Can parallelize with |
| --- | --- | --- | --- |
| 1 | 없음 | 2 | 없음 |
| 2 | 1 | 3 | 없음 |
| 3 | 2 및 운영 적용 승인 | F1-F4 | 없음 |

## Todos
> Implementation + Test = ONE todo. Never separate.
<!-- APPEND TASK BATCHES BELOW THIS LINE WITH edit/apply_patch - never rewrite the headers above. -->
- [x] 1. 실제 실행 원본과 격리된 장애 재현 기반 고정
  What to do / Must NOT do (allowed write paths): 실제 원본의 feature worktree에 `docker-compose.qa.yml`, `scripts/qa-runtime.sh`, `doc/evidence/kakaotalk-runtime-reliability/`만 추가한다. Git 상태/원본 해시/Compose labels/image/volume 이름을 기록하고 운영과 QA 자원 이름의 교집합이 있으면 실행을 거부한다. QA Compose는 전체 독립 서비스 선언으로 작성해 ports/volumes/container_name이 merge로 섞이지 않게 한다. 기존 실행 이미지와 동일 패키지/카톡 기반의 기준 이미지를 별도 태그로 보존하고, Dockerfile의 가변 apt 의존성 때문에 기준/수정 비교에서 Wine 버전이 바뀌지 않았음을 기록한다. 패키지가 달라졌으면 생명주기 코드만 원본으로 되돌린 격리 mutation 비교를 사용한다.
  Closes: GAP-1, GAP-5. Components: C1, C3.
  Parallelization: Wave 1 | Blocked by: 없음 | Blocks: 2.
  References: `/home/root1/kakaotalk-web/docker-compose.yml:1-29`, `docker/entrypoint.sh:170-209,262-288`, `docker/run-kakao.sh:88-112`, `README.md:86-102,144-155`; Docker restart 계약 https://docs.docker.com/engine/containers/start-containers-automatically/ . 경로는 별도 표기 없으면 실제 원본 기준이다.
  Acceptance criteria: `bash scripts/qa-runtime.sh baseline`가 실제 격리 noVNC에서 정상 연결을 확인한 뒤 x11vnc에 TERM을 보낸다. 이후 HTTP는 200이어도 RFB 연결은 실패하고 자동 복구되지 않는 기준 동작을 증거로 남긴다. `baseline`은 결함 재현 성공과 시스템 정상 판정을 혼동하지 않는 별도 exit/status 필드를 사용한다. 실제 실행 원본과 image, tested source revision을 manifest에 기록한다.
  QA scenarios: happy=`docker inspect kakaotalk-wine` read-only와 런타임 파일 SHA256 비교, QA 브라우저 `http://localhost:24500/vnc.html?autoconnect=true&resize=scale` 연결. failure=`bash scripts/qa-runtime.sh baseline` 내 QA 컨테이너의 정확한 x11vnc PID에 TERM, RFB 실패 관측. guard=운영 container_name/volume을 넣은 QA 설정을 드라이버에 주면 어떠한 kill/up/down 전에 거부해야 한다. Evidence `task-1-baseline.json`, `task-1-browser.json`, `task-1-cleanup.json`.
  Recommended task executor category: runtime investigation | native role: default task (agent 생략) | reason: 실제 Docker 상태와 격리 QA 계약을 한 소유자가 결박한다.
  Commit: N | 제안 subject: `Add isolated KakaoTalk runtime failure reproduction`.

- [x] 2. 앱 생명주기 감시와 계층별 상태·제한된 자동 복구 구현
  What to do / Must NOT do (allowed write paths): `docker/entrypoint.sh`, `docker/run-kakao.sh`, 새 `docker/healthcheck.sh`, `Dockerfile`, `docker-compose.yml`, `docker-compose.qa.yml`, `scripts/qa-runtime.sh`, 해당 evidence만 변경한다. 외부 supervisor/autoheal/Docker socket mount를 추가하지 않는다.
  구현 계약: Xvfb를 먼저 시작하고 준비를 확인한 뒤 Wine 초기화/튜닝을 수행한다. `wineboot`가 성공하고 완료한 경우에만 `.initialized`를 생성한다. 기존 prefix를 다시 초기화하거나 바이너리 업데이트 규칙을 확장하지 않는다. 부팅 준비 제한은 90초다.
  생명주기: Xvfb/openbox/x11vnc/websockify와 전용 monitor의 PID를 부모가 보유한다. runner/launcher 종료 자체를 실제 앱 종료로 오인하지 않고 컨테이너 내 정확한 `KakaoTalk.exe` 프로세스 존재를 확인한다. runner의 기존 창 앞으로 가져오기/매핑 기능은 유지하되 프로세스가 있는데 창이 없다는 이유로 `pkill`하는 기존 경로는 제거한다. 해당 상태는 UI 미확인으로만 기록한다. 동시에 두 앱을 실행하지 않도록 monitor 한 소유자가 앱 재실행을 직렬화한다.
  probe 계약: `/usr/local/bin/kakao-healthcheck`는 X round-trip(`timeout 3 xdpyinfo`), loopback 5900 RFB 12-byte banner(`RFB 003.` 접두부, Bash /dev/tcp와 timeout 3), HTTP GET(`wget` timeout 3), 실제 앱 프로세스를 각각 확인한다. `phase=starting|ready|degraded|blocked`, `layer=x|vnc|web|app`, reason을 단일 기계 판독 레코드로 출력하고 ready만 0, 나머지는 비0이다. 로그인 성공이나 UI 응답 보장은 의미하지 않는다. 기본 monitor interval 10초(동시 probe 금지), 연속 실패 3회, startup grace 90초. Docker healthcheck와 monitor는 이 probe 한 구현을 공유하고 전체 probe/healthcheck 상한을 12초로 맞춘다.
  복구 계약: 필수 프로세스 종료 또는 grace 후 연속 probe 실패 때 제한된 진단을 먼저 남긴다. app은 실제 프로세스가 없을 때만 동일 Wine 세션에서 runner 재실행; VNC/web은 해당 프로세스만 bounded TERM/KILL 후 기존 인자로 재실행한다. 일반 복구에서 `wineserver -k` 금지. Xvfb/openbox 공유 기반 실패 또는 동일 계층 1회 복구가 90초 안에 ready로 돌아오지 않으면 전체 bounded cleanup과 비0 종료로 격상하고 `unless-stopped`가 컨테이너를 다시 띄운다. 모든 자동 재실행/전체 종료가 같은 3회/10분 예산을 사용한다. 실패한 단계 복구와 뒤이은 전체 격상은 각각 1회다. `/data/runtime-state/`의 작은 상태 파일을 부모 한 소유자가 원자적 rename으로 기록한다. 전체 10분 연속 정상 상태 뒤 예산을 초기화한다. 예산 초과면 추가 자동 조치를 멈추고 `blocked`로 대기하며 진단/수동 복구만 허용한다. 수동 docker stop은 재시작하지 않고 예산을 소모하지 않는다. 명시 수동 복구나 새 이미지 ID 적용은 기록 후 예산을 리셋한다. 초기화/X 준비 실패를 포함해 모든 자동 재시작 경로에서 동일 예산을 확인하여 부팅 실패 루프도 차단한다.
  정리/로그: 정상/실패 종료 모두 trap을 사용하되 실패 exit code를 유지한다. Wine 종료 대기 상한 15초, 전체 cleanup 상한 20초, Compose stop_grace_period 30초. 무한 `wineserver -w` 대기 금지. 로그는 phase/layer/reason/time/recovery-count 중심 stdout + `/data/runtime-state/last-failure.log` 최대 64KiB 한 파일로 남긴다. 토큰/환경변수 전체/비밀번호/채팅·창 제목은 기록하지 않는다.
  Closes: GAP-2, GAP-3, GAP-4. Components: C2, C3.
  Parallelization: Wave 2 | Blocked by: 1 | Blocks: 3.
  References: 실제 `docker/entrypoint.sh:53-58,125-150,170-209,262-288`, `docker/run-kakao.sh:29-61,81-112`, `docker-compose.yml:9-26`; todo 1 baseline evidence. Docker health의 unhealthy 자체는 restart trigger가 아님을 유지한다.
  Acceptance criteria: `bash scripts/qa-runtime.sh recovery`에서 실제 app/Xvfb/x11vnc/websockify 종료 각각에 대해 source revision과 이미지 ID를 기록하고, 장애 주입 시각부터 240초 이내 해당 계층 또는 전체 컨테이너가 ready가 되어 웹 RFB 연결과 카톡 로그인 화면이 돌아오면 PASS. app/VNC/web의 단일 장애에서는 container ID/RestartCount와 살아 있는 다른 계층 PID가 유지되어야 한다. 카톡 launcher가 끝나도 실제 앱이 살아 있으면 재시작 0회. 무한 루프 없는 예산 초과 blocked, 수동 stop 유지, 초기화 실패 시 marker 미생성, 최소화·로그인 대기에서 불필요 재시작 0회가 모두 충족되어야 한다.
  QA scenarios: happy=`bash scripts/qa-runtime.sh healthy`, browser viewport desktop 1440x1000/mobile 390x844에서 연결 상태·canvas 크기·overflow DOM 측정 후 필요한 스크린샷만 저장, 시험용 한글 문자열을 로그인 ID 입력 칸에 입력 후 지움(로그인/전송 금지). failure=`bash scripts/qa-runtime.sh recovery`가 QA PID만 TERM하는 각 case를 실행; freeze=QA x11vnc에 STOP 후 probe degraded와 재기동 관측; regression=`bash scripts/qa-runtime.sh nonfaults`에서 app 살아 있는 launcher 종료/트레이 최소화/로그인 대기 오판 없음. circuit=`bash scripts/qa-runtime.sh circuit`에서 가짜 시계 기반 같은 예산 함수를 검증하고 격리 실제 연속 실패로 blocked 전이 확인. init-failure=격리 wineboot 실패 주입 시 marker 없음. mutant=복구 분기를 제거한 격리 코드에서 recovery case FAIL을 확인해 테스트가 결함을 잡는지 검증. Evidence `task-2-recovery.json`, `task-2-nonfaults.json`, `task-2-browser.json`, `task-2-mutation.json`, `task-2-cleanup.json`.
  Recommended task executor category: runtime lifecycle | native role: default task (agent 생략) | reason: Bash/Wine 생명주기와 테스트를 함께 고쳐야 한다.
  Commit: N | 제안 subject: `Recover failed KakaoTalk desktop services with bounded supervision`.

- [x] 3. 진단·수동 복구·데이터 보존 롤아웃과 사용자 화면 검증
  What to do / Must NOT do (allowed write paths): 새 `scripts/kakaoctl.sh`, `README.md`, `scripts/qa-runtime.sh`, evidence만 변경한다. 명령은 `status`, `diagnose`, `restart` 세 가지이며 대상 Compose project/container를 명시하고 검증한다. status/diagnose는 읽기 전용이고 runtime layer/phase/image/source/recovery reason을 출력한다. restart는 소량 진단을 먼저 남기고 복구 예산만 리셋해 `docker restart`한다. WINEPREFIX/.initialized/앱 데이터나 비밀번호를 손대지 않는다. 창만 숨은 경우 기존 실행 스크립트의 창 복구를 우선 안내하고 UI hang은 명시 restart로만 다룬다.
  Closes: GAP-3, GAP-4, GAP-5. Components: C1, C3.
  Parallelization: Wave 3 | Blocked by: 2 및 운영 적용 승인 | Blocks: F1-F4.
  References: 실제 `README.md:86-102,133-162`, `docker/entrypoint.sh:22-58,262-288`, `docker-compose.yml:14-17`; todo 2 상태/로그/예산 계약.
  배포 계약: QA는 빈 전용 volume으로 완료한다. 운영 변경 전에 이미지 ID·컨테이너 inspect·resolved Compose(비밀값 제외)와 기존 volume 이름을 기록한다. 사용자에게 이 준비 결과와 중단/복구 방법을 제시하고 운영 적용 승인을 받는다. 승인 전 중단/백업/재생성하지 않는다. 승인 후 운영 컨테이너를 정상 stop하고 정지된 `/data`를 접근 제한된 로컬 백업으로 복사한 뒤 실제 백업의 복원 가능성을 별도 QA volume에서 확인한다. 백업은 비밀 자료이며 git/evidence/공유폴더에 넣지 않는다. QA volume과 운영 volume을 절대로 같은 Wine 인스턴스에 동시 연결하지 않는다.
  롤아웃은 실제 프로젝트 `kakaotalk-web`와 기존 `kakaotalk-web_kakao-wine-data`를 그대로 사용한다. 새 feature worktree로 실행하더라도 `-p kakaotalk-web`와 운영 `.env`를 명시해 새 빈 volume이 생기지 않게 한다. 기존 태그 덮어쓰기 대신 release image ID를 고정해 up한다. 실패 시 기존 이미지 ID+기존 Compose+기존 volume으로 복귀하며 자동 앱 업그레이드는 실행하지 않는다. prefix 데이터까지 되돌려야 하면 먼저 실패 상태를 별도 보존하고 정지 상태에서 승인된 백업으로 복구한다. 복원/롤백 시험은 QA에서 먼저 수행한다.
  Acceptance criteria: `bash scripts/qa-runtime.sh operations`에서 status/diagnose/restart의 올바른 대상·비밀값 비노출·예산 리셋 및 영속 sentinel 유지·registry 가독성·명령 실패 exit code 전파를 확인한다. Wine registry는 정상 실행/종료 중 정당하게 변하므로 전체 hash 동일성을 요구하지 않고 정지된 백업과 복원본의 파일 hash만 비교한다. 승인된 운영 적용 뒤 literal 기존 URL에서 RFB 연결·기존 카톡 화면과 로그인 유지·입력 사용 가능 확인이 PASS여야 운영 완료다. 자동로그인 세션이 외부 정책으로 만료돼 있으면 이를 구별해 기록하고 재로그인 성공이라고 꾸미지 않는다. 적용 승인이 없으면 운영 미적용 상태로 정직하게 인계한다.
  QA scenarios: happy=`bash scripts/qa-runtime.sh operations` 및 실제 URL `http://localhost:14500/vnc.html?autoconnect=true&resize=scale` 연결, desktop/mobile DOM 측정과 비민감 영역 screenshot. failure=QA 잘못된 target에서 안전 거부, QA 이미지 부팅 실패 후 이전 이미지+동일 sentinel volume으로 rollback, 백업을 새 QA volume에 복원해 registry/sentinel 확인. UI 입력은 실제 대화가 아닌 검색창에 시험 문자열 입력 후 즉시 지우며 메시지 전송/로그인 변경 금지. `diagnose` 출력에 `.env`의 비밀 sentinel이 없는지도 QA로 확인한다. RDP는 포트/RFB relay smoke만 확인하고 새 클라이언트 설치는 하지 않는다. Evidence `task-3-operations.json`, `task-3-volume.json`, `task-3-rollback.json`, `task-3-live-browser.json`, `task-3-cleanup.json`.
  Recommended task executor category: operational verification | native role: default task (agent 생략) | reason: 승인 경계와 사용자 로그인 데이터 보존을 함께 검증한다.
  Commit: N | 제안 subject: `Document and verify safe KakaoTalk recovery and rollback`.

## Final verification wave
> Runs in parallel after ALL todos. ALL must APPROVE. Surface results and wait for the user's explicit okay before declaring complete.
- [ ] F1. Plan compliance audit
  읽기 전용 reviewer가 실제 diff와 evidence manifest의 revision/image를 대조하고 IS/GAP 매핑·승인 범위·잘못된 사본 수정 없음을 판정한다. Evidence `final-F1.json`.
- [ ] F2. Code quality review
  읽기 전용 reviewer가 PID/launcher 구별, trap/exit code, 초기화 marker, bounded cleanup, 예산·비밀값·volume 보호를 점검한다. 실행자는 `bash -n docker/entrypoint.sh docker/run-kakao.sh docker/healthcheck.sh scripts/kakaoctl.sh scripts/qa-runtime.sh`와 `docker compose config --quiet`, 격리 build/QA 전체를 한 차례 실행하고 결과를 제공한다. 기존 테스트가 새로 발견되면 해당 전체 suite도 실행한다. Evidence `final-F2.json`.
- [ ] F3. Real manual QA
  실제 noVNC 연결·화면·한글 입력, 고장 주입 후 재연결, 수동 멈춤 복구, 데이터 보존/롤백 증거를 확인한다. HTTP200/fixture/exit0만으로 PASS 금지. 승인된 운영 확인이 빠졌으면 운영 완료는 보류한다. Evidence `final-F3.json`.
- [ ] F4. Ideal-state fidelity
  IS-1~5를 1:1로 성공 기준 표에 대조한다. 일반 Wine hang/서버 장애까지 자동 치유한다고 주장하지 않는지 확인한다. QA의 컨테이너/volume/network/브라우저 탭/임시 mutation/민감 백업 처리와 포트 24500/23389 해제 기록이 없으면 FAIL. 운영 리소스는 정리 대상이 아니다. Evidence `final-F4.json`.

## Commit strategy
Branch: `feature/202610-kakaotalk-runtime-reliability`. 실제 구현 원본 `/home/root1/kakaotalk-web@91cff7e`에서 별도 `/home/root1/work/kakaotalk-runtime-reliability` worktree를 만든다. main 직접 수정 금지. 계획 문서는 현재 작업 저장소 doc/에 보관하므로 실행자가 이 계획의 절대 경로를 읽는다. Commit: N. Push/merge: N. Stage/commit owner는 부모 실행자 한 명이며 현재 승인 없음. 사용자가 이후 명시 승인하면 `git log`의 기존 subject 스타일로 검증 단위별 커밋하고 `Plan: doc/plans/kakaotalk-runtime-reliability.md`를 기록한다. 운영 적용은 별도 승인이다. 기존 작업 사본의 `yearistype.sh` 수정은 보존하고 건드리지 않는다.

## Success criteria
> One row per IS row. The plan is complete only when every IS row has a delivering todo and a proving QA scenario; F4 checks the delivered behavior against these rows 1:1, and a shortfall becomes new `- [ ] N.` rows, never a note.
| IS | Delivering todo(s) | Proving QA scenario | Evidence |
| --- | --- | --- | --- |
| IS-1 | 1, 2, 3 | 실제 noVNC RFB 연결, desktop/mobile 측정, 비전송 한글 입력 | task-2-browser.json, task-3-live-browser.json |
| IS-2 | 2 | recovery: app/Xvfb/VNC/web 각각 장애 주입 후 240초 이내 실제 화면 복귀, 단일 계층 장애의 복구 범위 확인, mutation에서 실패 | task-2-recovery.json, task-2-mutation.json |
| IS-3 | 2 | nonfaults에서 재시작 0회, circuit에서 blocked, 수동 stop 유지 | task-2-nonfaults.json, task-2-recovery.json |
| IS-4 | 2, 3 | 초기화 실패 marker 미생성, 정상 종료와 운영/QA backup-restore/rollback, volume 유지 | task-3-volume.json, task-3-rollback.json |
| IS-5 | 3 | status/diagnose 및 명시 restart, UI hang 자동 감지 한계 명시, 비밀값 비노출 | task-3-operations.json |
