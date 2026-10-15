# KakaoTalk Docker (Windows / WSL)

Windows Docker Desktop 또는 WSL(Windows Subsystem for Linux) 환경의 Docker Engine에서 KakaoTalk PC 버전을 실행하고, 브라우저에서 noVNC로 조작하는 개인용 환경입니다.

## 기능

- **KakaoTalk PC 버전 포함**: WineHQ staging 기반 64비트 Wine 환경 실행
- **Windows RDP 원격 데스크톱 지원**: xrdp를 통한 무손실 UTF-8 한글 양방향 클립보드 동기화 (`localhost:13389`)
- **브라우저 접속 화면**: noVNC 기반, 루트 URL(`http://localhost:14500`) 접속 시 자동 연결 및 크기 맞춤(scale)
- **한글 입력 지원**: fcitx5-hangul 기반 한영 전환 지원
- **선명한 폰트 렌더링**: NanumGothic 및 Noto CJK, Wine ClearType 서브픽셀 폰트 스무딩 적용
- **해상도 및 DPI 조절**: `RESOLUTION`(기본 1280x800) 및 `DPI`(기본 96, 고해상도 배율 지원) 환경변수 제공
- **스마트 링크 처리**: 카카오톡 내 링크 클릭 시 공유 폴더(`opened_urls.txt`)에 자동 기록되어 호스트 브라우저에서 바로 열람 가능 (Firefox 활성화 시 컨테이너 브라우저로 실행)
- **보안 강화**: VNC 내부 루프백 바인딩 및 선택적 VNC 비밀번호(`VNC_PASSWORD`) 설정 지원
- **안정적인 프로세스 라이프사이클**: `wineserver -k` 종료 트랩을 통한 Wine 레지스트리/데이터 손상 방지
- **볼륨 자동 동기화**: 이미지 업데이트 시 `/data` 볼륨 내 바이너리 버전 비교 후 자동 업데이트
- **Windows 폴더 ↔ 컨테이너 파일 공유 지원** (`Z:\share`)

## 설치 및 실행 환경

이 환경은 아래 두 가지 환경을 모두 지원합니다.
1. **Windows Docker Desktop**
2. **WSL2 (Ubuntu 등) 환경에 직접 설치한 Docker Engine (docker-ce)**

---

## 설치 및 설정

### 1. 설정 파일 복사 및 공유 폴더 경로 수정
저장소를 클론한 뒤 `.env.example`을 `.env`로 복사합니다.

```bash
cp .env.example .env
```

`.env` 파일을 열어 공유 폴더 경로(`KAKAO_SHARE_DIR`)를 본인 환경에 맞게 수정합니다.

**Windows Docker Desktop 또는 WSL에서 Windows 폴더를 공유할 경우:**
```env
KAKAO_SHARE_DIR=/mnt/c/Users/사용자이름/Desktop/kakao-share
```

**WSL 전용 경로(Linux 내부 경로)를 공유할 경우:**
```env
KAKAO_SHARE_DIR=/home/사용자이름/kakao-share
```

### 2. 브라우저 옵션 설정 (선택 사항)
웹 브라우저(Firefox)는 기본으로 비활성화되어 있습니다. 카카오톡만 사용할 경우 그대로 두세요.
```env
INSTALL_FIREFOX=false
ENABLE_FIREFOX=false
```

브라우저까지 컨테이너 내부에 포함해서 실행하려면 `.env`에서 아래처럼 바꾼 뒤 빌드합니다.
```env
INSTALL_FIREFOX=true
ENABLE_FIREFOX=true
```

### 3. 공유 폴더 생성
설정한 경로에 맞춰 공유 폴더를 미리 생성해 둡니다.

**Windows Desktop 경로 예시:**
```bash
mkdir -p /mnt/c/Users/사용자이름/Desktop/kakao-share
```

**WSL 내부 경로 예시:**
```bash
mkdir -p ~/kakao-share
```

### 4. 빌드 및 컨테이너 실행
프로젝트 루트 폴더(예: `kakaotalk-web`)에서 아래 명령을 실행합니다.
*(WSL에 직접 설치한 Docker의 경우 권한에 따라 앞에 `sudo`를 붙여야 할 수 있습니다.)*

```bash
# 빌드
docker compose build --no-cache

# 실행
docker compose up -d
```

### 5. 화면 접속 방법

#### 방법 A: Windows 원격 데스크톱 (RDP, 권장)
Windows 클라이언트와 카카오톡 간의 **완벽한 한글 클립보드 양방향 복사/붙여넣기**를 지원합니다.

1. Windows `실행`(Win + R) 창에서 `mstsc`를 실행하거나, 프로젝트 루트에 있는 `KakaoTalk-RDP.rdp` 파일을 더블클릭합니다.
2. 컴퓨터 주소에 아래와 같이 입력하고 연결합니다:
   ```text
   localhost:13389
   ```

#### 방법 B: 웹 브라우저 (noVNC)
별도 클라이언트 없이 웹 브라우저를 열고 아래 주소로 접속하면 카카오톡 화면이 자동으로 연결됩니다:
```text
http://localhost:14500
```
*(기존 쿼리 파라미터 URL인 `http://localhost:14500/vnc.html?autoconnect=true&resize=scale`도 계속 사용 가능합니다.)*

---

## 고급 설정 (.env)

`.env` 파일에서 다양한 옵션을 변경할 수 있습니다.

### 해상도 및 고해상도(HiDPI) 배율 조절
```env
# 가상 디스플레이 해상도 설정 (기본값: 1280x800)
RESOLUTION=1920x1080

# Wine UI 배율 / DPI 설정 (기본값: 96)
# 96: 100% (기본 모니터)
# 120: 125% (QHD 또는 작은 글씨 확대)
# 144: 150% (4K 모니터 권장)
DPI=120
```

### VNC 접속 비밀번호 설정
```env
# 비밀번호를 설정하면 웹 접속 시 인증 창이 뜹니다. (미설정 시 무인증)
VNC_PASSWORD=mysecretpassword
```

### 링크 클릭 처리 방식
카카오톡 채팅창이나 알림톡의 링크를 클릭하면:
- **기본 모드 (`ENABLE_FIREFOX=false`)**: 클릭한 URL이 공유 폴더 내 `opened_urls.txt`에 실시간으로 기록됩니다. 사용자는 Windows/WSL 호스트의 기본 브라우저(Chrome, Edge 등)에서 해당 링크를 바로 열 수 있습니다.
- **브라우저 모드 (`ENABLE_FIREFOX=true`)**: 컨테이너 내부에 설치된 Firefox 브라우저로 직접 URL이 열립니다.

## 평소 실행

```bash
cd /mnt/c/tmp/kakaotalk-web  # 또는 프로젝트를 클론한 경로
docker compose up -d
```

## 파일 전송

Windows 탐색기에서 `.env`에 설정한 공유 폴더에 파일을 넣으면, 카카오톡 파일 첨부창에서 `Z:\share` 폴더로 접근해 바로 선택할 수 있습니다.

## Docker 종료

```bash
docker compose down
```

## Docker 완전 초기화

카카오톡 로그인 상태와 Wine 환경까지 지우려면 volume을 같이 삭제합니다.

```bash
docker compose down -v
```

## 자가 복구와 운영 점검

컨테이너 안의 모니터가 10초마다 X 화면, VNC, noVNC 웹, `KakaoTalk.exe` 프로세스를 같은 probe(`kakao-healthcheck`)로 확인하고, 죽은 계층만 다시 띄웁니다. Docker `HEALTHCHECK`도 같은 probe를 씁니다.

- **복구 한도**: 10분 안에 자동 재실행·전체 종료 3회까지만 허용합니다. 한도를 넘으면 `blocked`가 되어 자동 조치를 멈추고 이유를 남깁니다(재시작 폭주 방지).
- **고장으로 보지 않는 것**: 창 최소화, 로그인 화면 대기, 수동 `docker stop`은 복구 대상이 아니며 한도에도 세지 않습니다.
- **한도 초기화**: 10분 연속 `ready`, `kakaoctl.sh restart`, 새 이미지 배포 중 하나.
- **데이터**: 복구·재시작은 `/data` 볼륨(Wine prefix, 로그인 데이터)을 지우거나 초기화하지 않습니다.

### 상태 표시

| phase | 의미 |
| --- | --- |
| `starting` | 부팅 또는 시작 유예 시간 중 |
| `ready` | X·VNC·웹·카카오톡 프로세스가 모두 응답 |
| `degraded` | 한 계층이 응답하지 않음(`layer`, `reason`에 표시), 모니터가 복구 시도 중 |
| `blocked` | 복구 한도 소진, 자동 조치 중단 — 수동 복구 필요 |

### kakaoctl 명령

```bash
bash scripts/kakaoctl.sh status                  # 읽기 전용: docker 상태/health, 이미지 ID, phase/layer/reason, 복구 예산
bash scripts/kakaoctl.sh diagnose                # status + 프로세스 목록, last-failure.log, 최근 런타임 로그
bash scripts/kakaoctl.sh restart                 # 진단 스냅샷 저장 → 복구 예산 초기화 표식 → docker restart
```

기본 대상은 `--project kakaotalk-web --container kakaotalk-wine`이며 다른 대상은 `--project`, `--container`로 지정합니다. 컨테이너가 없거나 Compose project 라벨이 다르면 아무것도 하지 않고 종료 코드 3으로 거부합니다. 비밀값(`VNC_PASSWORD` 등)과 환경변수는 출력하지 않으며, `docker` 명령이 실패하면 그 종료 코드를 그대로 돌려줍니다.

### 한계: UI 멈춤은 자동 감지하지 않음

`ready`는 네 계층이 응답한다는 뜻일 뿐 카카오톡 화면이 반응한다는 보장이 아닙니다. 프로세스는 살아 있는데 화면이 멈추거나 비어 있으면 자동으로 알 수 없으므로 `kakaoctl.sh restart`로 직접 복구하세요. 창이 숨겨졌을 뿐이라면 기존 runner가 다시 앞으로 올립니다.

```bash
docker exec kakaotalk-wine run-kakao
```

### 롤백

배포 전에 실행 중인 컨테이너를 그대로 이미지로 보존해 둡니다. 기존 컨테이너는 이미지(`dcdc7a66…`) 밖에서 고친 실행 스크립트를 쓰고 있었으므로, 원래 이미지 ID로 되돌리면 옛 스크립트로 돌아갑니다. 2026-10-15 배포 때 보존한 이미지는 `kakaotalk-wine:rollback-20261015`입니다. 문제가 있으면 이 이미지와 **같은 볼륨**(`kakaotalk-web_kakao-wine-data`)으로 되돌립니다.

```bash
docker stop -t 30 kakaotalk-wine && docker commit kakaotalk-wine kakaotalk-wine:rollback-$(date +%Y%m%d)   # 배포 전 보존
docker tag kakaotalk-wine:rollback-20261015 kakaotalk-wine:local                                          # 되돌릴 때
docker compose -p kakaotalk-web up -d --no-build --force-recreate
```

`--build`나 `docker compose down -v`는 쓰지 마세요(볼륨 삭제). 볼륨의 `runtime-state`는 이전 이미지가 무시하므로 그대로 둡니다.

## 주의

- 로컬/개인용으로만 사용하세요.
- 인터넷에 공개 서비스처럼 노출하지 마세요.
- KakaoTalk 바이너리 포함 배포는 KakaoTalk 라이선스와 이용약관을 직접 확인해야 합니다.
