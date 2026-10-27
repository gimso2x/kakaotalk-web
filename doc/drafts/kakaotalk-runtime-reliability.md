---
slug: kakaotalk-runtime-reliability
status: completed
intent: unclear
review_required: true
plan_path: doc/plans/kakaotalk-runtime-reliability.md
plan_sha256: cfef5272016ddb7e51d43839df30ea49d7cea81b3a344fd9f8711e5bb47c8627
review_round_id: 01a13cca-c299-76f7-9066-3038690c6664-r1
review_round_limit: 5
pending-action: none; planning complete; execution requires a separate user request
review:
  plan_reviewer:
    status: approved
    workspace_root: /home/root1/work/kakaotalk-web
    runtime_home: /home/root1/.omp/agent
    target: doc/plans/kakaotalk-runtime-reliability.md
    round_id: 01a13cca-c299-76f7-9066-3038690c6664-r1
    plan_sha256: cfef5272016ddb7e51d43839df30ea49d7cea81b3a344fd9f8711e5bb47c8627
    launch_id: ReliabilityPlanReviewR1
    session: agent://ReliabilityPlanReviewR1
    result: APPROVE with non-blocking notes; no blockers
approach: 사용자가 기존 웹 접속 유지와 자동 복구 보강을 선택함. 계층별 최소 복구, 제한된 전체 재기동, 데이터 보존.
---

# Draft: kakaotalk-runtime-reliability

## Affected user and ideal state
<!-- Who this output touches (a customer, another programmer, a program or agent consuming it - often more than one) and how each uses it today and will use it after. -->
<!-- IS-n | property of the ideal state: nothing snags, feels odd, regresses, or degrades for them | reason -->
<!-- GAP-n | difference between IS-n and today | reason | closed by todo(s) -->
영향 사용자: Windows 네이티브 카톡을 사용할 수 없어 localhost:14500을 쓰는 본인.
IS-1 | 기존 URL에서 실제 카톡 화면과 한글 입력을 쓴다 | HTTP200만으로 대체 불가.
IS-2 | 카톡/필수 서비스 종료 자동 복구 | 수동 재기동 감소.
IS-3 | 최소화/로그인 대기 오판 없음, 반복 고장 제한 | 작업 방해 방지.
IS-4 | 로그인/Wine 데이터 보존 | 백업/복구 검증.
IS-5 | 진단과 명시 수동 복구 | 일반 UI hang 자동 판별은 보장 안 함.
GAP-1~5 및 todo 매핑은 완성 계획 Scope/Success criteria에 기록됨.

## Components (topology ledger)
<!-- Lock the SHAPE before depth. One row per top-level component that can succeed or fail independently. -->
<!-- id | outcome (one line) | status: active|deferred | evidence path -->
C1 실행 원본과 릴리스/롤백; C2 Wine/카톡/화면 생명주기; C3 웹/VNC 상태와 진단. 전부 active, todo 1~3에 매핑.

## Open assumptions (announced defaults)
<!-- Intent is UNCLEAR: research resolves ambiguity, defaults are adopted (not asked), and each is surfaced in the plan's human TL;DR for veto. -->
<!-- assumption | adopted default | rationale | reversible? -->
기본값: 개인 1인 로컬 사용, 유료 인프라 추가 없음, 기존 볼륨 유지, 현재 호스트 유지. 모두 계획 단계에서 변경 가능. 플랫폼 전환은 사용자가 선택.

## Findings (cited - path:lines)
- 실제 원본: /home/root1/kakaotalk-web@91cff7e, main clean. Docker label의 Compose 경로 및 원본/런타임 SHA256 일치 확인.
- 실행 이미지 sha256:dcdc7a66f7ab925ca0d62c166b7407b9b1f635071d28aa92d59eb583e6bfc9a3; restart unless-stopped; Healthcheck=null.
- /home/root1/kakaotalk-web/docker/entrypoint.sh:288: wait websockify만 수행. run-kakao.sh:112는 Wine launcher PID 대기이므로 실제 앱 생명주기와 구별 필요.
- /home/root1/kakaotalk-web/docker-compose.yml:12-17: noVNC/RDP 및 지속 볼륨. RDP도 같은 Wine/Xvfb/x11vnc 의존.
- 실제 창 목록에서 카카오톡 확인. 재기동 전 장애 상태는 없어 원인 단정 금지.
- https://docs.docker.com/engine/containers/start-containers-automatically/ : restart policy는 컨테이너 종료 기반.
- 작업 사본 /home/root1/work/kakaotalk-web@d329c63, branch fix/build-stability-and-security, 기존 yearistype.sh 수정 보존.

## Decisions (with rationale)
계획 문서는 현재 작업 저장소 doc/에만 작성. 실제 구현 대상은 실행 원본이며, 별도 feature/202610-kakaotalk-runtime-reliability 브랜치/worktree 사용. Commit: N, push/merge/deploy 미승인. 제품 변경/추가 재기동 없음.

## Scope IN
선택한 우회 환경의 안정화 계획, 실제 장애와 구조적 위험 구별, 자동 복구 검증 및 데이터 보존/롤백.

## Scope OUT (Must NOT have)
Windows 네이티브 카톡 문제 조사, 실제 채팅 전송, 로그인 변경, 볼륨 삭제/초기화, 임의 업데이트/패키지 설치, 실행 설정 변경, 커밋/배포.

## Open questions
없음. 사용자가 A 기존 웹 접속 유지 + 자동 복구 보강을 선택함.

## Approval gate
status: approved-for-plan
pending-action: 독립 검토 완료 후 계획 인계. 구현 시작하지 않음.
approval: explicit plan request + native ask에서 기존 웹 접속 유지/자동 복구 보강 선택.
<!-- Set status: awaiting-approval ONLY when a genuine owner decision or ambiguous scope/plan selection survives exploration; ask it once. An explicit plan request with none left already authorizes the plan: record approval: explicit plan request instead and write it. Implementation, commits, pushes and deploys are never authorized by either. -->
<!-- When awaiting-approval, that durable record is the loop guard: on a later turn read it and resume at the gate instead of re-running exploration. -->

## Consultant receipt
ReliabilityConsultant (scout, read-only) 완료. launcher/app 분리, 창 부재 시 kill 제거, 계층별 복구, 반복 실패 제한, 이미지 롤백만으로 지속 볼륨 바이너리가 복귀하지 않는 점 반영. 부모가 실제 원문으로 확인.

## Review lifecycle
Round 1 initialized. Complete plan digest frozen; reviewer launch handle will be recorded immediately after dispatch. Maximum 5 fresh rounds. Block only explicit requirement/accepted decision, existing failing regression, reproducible broken flow, concrete security/data-loss/compatibility risk, external contract conflict, or unmapped/unreachable ideal state. Other findings are notes. No implementation verification has been run in plan-only mode.

## Review receipt: round 1
Reviewer: ReliabilityPlanReviewR1, native reviewer, read-only. Verdict: APPROVE. Blockers: none.
Round: 01a13cca-c299-76f7-9066-3038690c6664-r1.
Workspace: /home/root1/work/kakaotalk-web. Target: doc/plans/kakaotalk-runtime-reliability.md.
Approved SHA256: cfef5272016ddb7e51d43839df30ea49d7cea81b3a344fd9f8711e5bb47c8627.
Parent independently re-read the exact plan and matched the same SHA256 after review. Complete structural check passed (3 implementation tasks, 4 final verification tasks, 3 executor entries, template header order, no unfinished fill fields).
Non-blocking implementation notes, not changes to the frozen plan:
- N1: Evidence manifest must hash new/untracked and staged files individually; git diff --binary alone does not identify all exercised files.
- N2: Record existing/candidate Wine and KakaoTalk versions separately. A same-image lifecycle mutation proves recovery behavior, not permission to change runtime versions.
- N3: Each isolated fault case must reset its QA recovery budget or use fresh QA runtime state. Only the circuit case deliberately accumulates failures.
No plan blockers remain. These notes are execution inputs; approval does not claim implementation tests or live stability have passed.
Cleanup receipt: no QA server/container/browser/volume/temp resource created in this planning run; no runtime changes. Working branch fix/build-stability-and-security has 3 uncommitted files: existing yearistype.sh plus draft and plan; no staging/commit. Actual runtime repository remains untouched.
