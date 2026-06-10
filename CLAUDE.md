# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

사내망(인터넷 차단 환경)용 **오프라인 PyPI 서버** 도커 이미지를 만드는 프로젝트.
패키지(.whl / sdist)를 이미지 빌드 시점에 전부 내려받아 이미지 내부에 박아두고,
런타임에는 외부망 없이 [`pypiserver`](https://github.com/pypiserver/pypiserver)(무인증)로 서빙한다.

대상 클라이언트는 **Windows x64 / Python 3.12 또는 3.13 전용** (Linux 클라이언트 미지원).
서버 컨테이너 자체는 `linux/amd64` 위에서 동작한다. 이미지: `docker.io/joelkim/pypi`.

문서·주석·커밋 메시지는 한국어로 작성되어 있다 — 동일 언어/톤을 유지할 것.

## 자주 쓰는 명령

```bash
# 로컬 빌드 + Docker Hub 푸시 (PYVER 기본 3.13)
./1_build_image.sh                       # build + push
./1_build_image.sh --no-push             # 로컬 빌드만
PYVER=3.12 ./1_build_image.sh --no-push  # Python 3.12 로컬 빌드만

# 로컬 테스트 컨테이너 기동
./2_run_container.sh                       # py313win_latest, 포트 8080
PYVER=3.12 PORT=9000 ./2_run_container.sh  # 3.12 이미지, 9000 포트

# 스모크 테스트 (컨테이너 기동 후)
curl -fsS http://localhost:8080/simple/ | head
pip install --index-url http://localhost:8080/simple/ --trusted-host localhost requests
```

빌드 도구는 **podman** (`docker` 아님). 푸시 전 `podman login docker.io` 필요.
별도의 lint/test 스위트는 없다 — 검증은 위 스모크 테스트로 한다.

## 아키텍처

3개의 핵심 파일이 맞물려 동작한다. 어느 하나를 바꿀 때 나머지의 가정을 깨지 않도록 주의:

1. **requirements.txt** — 미러에 담을 최상위 패키지 목록. transitive 의존성은
   빌드 시 자동 해결된다. 재현성을 위해 버전 pin 권장.

2. **download_packages.sh** — Dockerfile Stage 1에서 실행되는 다운로더. 3단계:
   - **Phase 0**: `uv pip compile --python-platform windows --python-version <PYVER>`
     로 의존성 그래프를 해결한다. **핵심**: 빌드 컨테이너는 Linux이지만 *Windows
     환경 마커*로 평가하므로 `pywin32-ctypes`, `colorama` 같은 Windows 전용
     의존성이 포함되고, `uvloop` 같은 Linux 전용 의존성은 자동 배제된다.
     (과거 `pip download`(Linux 마커) 방식은 Windows 전용 의존성을 누락했다.)
   - **Phase 1**: 각 패키지를 `--platform win_amd64` wheel로 다운로드.
   - **Phase 2**: Windows wheel이 없으면 sdist로 폴백.
   - `SKIP_PACKAGES` 배열은 안전망 — PyPI에 Windows 배포 파일이 전혀 없어
     다운로드가 실패하는 패키지를 등록하면 빌드 실패에서 제외된다. Windows 마커
     해결 덕분에 보통 비어 있다. 패키지 하나라도 다운로드 실패하면 스크립트는
     `exit 1`로 빌드를 깨뜨린다(의도된 미지원이면 `SKIP_PACKAGES`에 추가).

3. **Dockerfile** — 멀티스테이지. Stage 1(`downloader`)이 `/wheels`에 패키지를
   모으고, Stage 2가 `pypiserver[passlib]` + `gunicorn`을 설치한 뒤 `/wheels`를
   `/data/packages`로 복사한다. 런타임은 **gunicorn 뒤에 pypiserver WSGI 앱**
   (`pypiserver:app(roots="/data/packages")`)을 올려 서빙한다 — 자세한 내용은
   아래 "동시성/서버" 참조. `ARG PYTHON_VERSION`(기본 3.13)이 베이스 이미지·
   다운로더·서버 전부의 Python 버전을 결정한다.

### 동시성/서버

런타임 CMD는 `pypi-server run`(단일 wsgiref) 이 아니라 **gunicorn**이다:

```
gunicorn -k gthread -w ${WEB_CONCURRENCY} --threads ${GUNICORN_THREADS} \
  --timeout ${GUNICORN_TIMEOUT} -b 0.0.0.0:8080 'pypiserver:app(roots="/data/packages")'
```

- 과거 단일 wsgiref 서버는 싱글스레드라 uv의 병렬 커넥션에 큐가 밀려 헬스체크
  실패→재시작으로 "자꾸 죽는" 증상이 있었다. gthread 멀티 워커로 해결.
- 동시 처리량 ≈ `WEB_CONCURRENCY`(워커) × `GUNICORN_THREADS`(스레드). 기본
  4×8=32. 환경변수로 런타임에 덮어쓴다: `docker run -e WEB_CONCURRENCY=8 ...`.
- install(읽기)은 pypiserver 기본이 익명 허용이라 별도 인증 인자가 필요 없다
  (기존 `-a . -P .` 가 열어주던 익명 *업로드*는 빠짐 — 읽기 전용 미러라 무방).
- 런타임에 추가 wheel 디렉터리를 더 서빙하려면 roots에 리스트를 넘긴다:
  `pypiserver:app(roots=["/data/packages","/data/extra"])`.

### 빌드/배포 흐름

- main 브랜치에 `Dockerfile` / `requirements.txt` / `download_packages.sh` /
  워크플로 변경이 푸시되면 `.github/workflows/build-push.yml`이 **3.12와 3.13을
  동시에** 빌드/푸시한다 (`workflow_dispatch` 수동 트리거도 지원).
- GitHub Secrets에 `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` 필요.

### 이미지 태그 규칙

- `py{312,313}win_YYYYMMDDTHHMMSS` — 빌드 타임스탬프(Asia/Seoul), **불변**. 롤백용.
- `py{312,313}win_latest` — **가변**. 항상 최신을 가리킴.
- `_latest`는 가변이라 사내 서버에 옛 캐시가 남으면 `docker run`이 옛 이미지를
  그대로 띄우는 함정이 있다. 그래서 `2_run_container.sh`는 `--pull=newer`를 쓴다.
  "빌드 로그엔 패키지가 보이는데 `/data/packages`는 비어 있다"면 이 캐시 문제다.

## 패키지 추가/변경 절차

1. `requirements.txt` 수정 (버전 pin 권장).
2. main에 푸시 → Actions가 3.12/3.13 모두 재빌드/푸시.

sdist만 있는 패키지는 Windows 클라이언트 설치 시 컴파일러 등 빌드 도구가 필요할 수
있으니, 가능하면 wheel이 제공되는 버전으로 pin하는 편이 안정적이다.
