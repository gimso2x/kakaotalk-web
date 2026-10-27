# Handoff: kakaotalk-runtime-reliability (2026-10-15, 2차)

## 상태
- 구현 커밋 `6085e9d`가 `/home/root1/kakaotalk-web` main에 fast-forward 병합되어 있고, origin(github.com/gimso2x/kakaotalk-web)에도 push했다. upstream에는 push하지 않았다.
- feature 브랜치와 worktree `/home/root1/work/kakaotalk-runtime-reliability`는 삭제했다.
- 운영 `kakaotalk-wine`은 원본 체크아웃에서 `docker compose -p kakaotalk-web up -d --no-build`로 다시 만들었다.
  - 이미지는 `kakaotalk-wine:local` = `8163bb6e`(자가 복구 버전)이다.
  - 볼륨은 기존 `kakaotalk-web_kakao-wine-data`이고, `/share` 마운트도 유지했다.
  - healthy이고 창 3개가 관리되고 있다. 로그인 화면은 자동 로그인이 꺼진 기존 설정 그대로다.
- 마지막 기동 직후 앱이 한 번 종료돼(launcher exit 9) monitor가 1회 재실행했다. recovery_count는 1이다.
- 남긴 안전망은 다음 두 가지다. 필요 없으면 사용자 확인 뒤 지운다.
  - 롤백 이미지 `kakaotalk-wine:rollback-20261015`(6aaf2d6d)
  - 백업 `/home/root1/kakao-backup/kakao-wine-data-20261015.tar.gz`(0600, 계정 데이터 포함)
- QA 이미지 태그(reliability-baseline/qa/release/release2)는 삭제했다. QA 컨테이너와 볼륨은 남은 것이 없다.

## 미완료와 후속 후보
- 계획의 F1~F4 최종 리뷰는 사용자가 빠른 마무리를 선택해 생략했다. Boulder 상태는 `paused`다.
- openbox 정지는 재현하지 못했다. 수정은 openbox를 Wine 작업 전에 띄우는 것으로, 원인은 추정이다.
  - healthcheck는 "WM이 창을 관리하지 않음" 상태를 감지하지 못한다. 후속으로 `_NET_CLIENT_LIST`가 비었거나 tint2가 unmapped인 상태를 감지하는 가드를 추가하는 것을 권장한다.
- 실제 화면의 한글 입력 확인과 백업 복원 리허설은 하지 않았다.
- 이미지에 들어 있는 카톡은 26.1.2다. 새 볼륨에서는 "파일 손상" 대화상자가 뜬다. 운영 볼륨은 26.8.2라서 해당되지 않는다.
