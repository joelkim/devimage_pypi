# devimage_pypi

사내망(인터넷 차단 환경)에서 동작하는 **오프라인 PyPI 서버** 도커 이미지.
패키지(.whl / .tar.gz)는 이미지 빌드 시점에 내려받아 이미지 내부에 통째로 박아둔다.
런타임에 외부망 접근이 전혀 필요하지 않다.

- 베이스: `python:<버전>-slim` (Python 버전은 빌드 시 결정 — 기본 3.13)
- 서버: [`pypiserver`](https://github.com/pypiserver/pypiserver) (무인증)
- 대상 클라이언트: **Python 3.12 또는 3.13 / Windows x64 전용** (Linux 미지원)
- 이미지 아키텍처: `linux/amd64` (서버 컨테이너는 Linux 위에서 동작)
- 패키지 형식: **Windows wheel 우선, 없으면 sdist 폴백** (`download_packages.sh` 참조)
- 이미지: `docker.io/joelkim/pypi`

---

## 이미지 태그 형식

| 태그 | 의미 |
| --- | --- |
| `py312win_YYYYMMDDTHHMMSS` | Python 3.12 / Windows x64, 빌드 타임스탬프 (UTC, 불변) |
| `py312win_latest`   | Python 3.12 / Windows x64, 최신 빌드 (가변, 항상 최신 가리킴) |
| `py313win_YYYYMMDDTHHMMSS` | Python 3.13 / Windows x64, 빌드 타임스탬프 (UTC, 불변) |
| `py313win_latest`   | Python 3.13 / Windows x64, 최신 빌드 (가변, 항상 최신 가리킴) |

- **타임스탬프 태그** (예: `py313win_20260529T042130`): 각 빌드마다 고유. 불변이므로 과거 버전 보관/롤백에 사용.
- **`_latest` 태그**: 가변. 항상 최신 빌드를 가리킴. 클라이언트에서 `docker pull` / `--pull=newer` 필수.

GitHub Actions 는 main 브랜치 푸시 시 `3.12` 와 `3.13` 두 버전을 동시에 빌드/푸시한다.

---

## 디렉터리 구성

| 파일 | 역할 |
| --- | --- |
| `Dockerfile` | 멀티스테이지 빌드 — 1단계 패키지 수집, 2단계 pypiserver. `ARG PYTHON_VERSION` 사용 |
| `requirements.txt` | 미러에 포함할 패키지 목록 (transitive deps도 명시 권장) |
| `download_packages.sh` | Windows wheel 우선 다운로드 + sdist 폴백 |
| `1_build_image.sh` | 로컬 빌드 + Docker Hub 푸시 (podman, linux/amd64) |
| `2_run_container.sh` | 로컬 테스트용 컨테이너 기동 |
| `.github/workflows/build-push.yml` | Python 3.12/3.13 두 버전 자동 빌드/푸시 |

---

## 사용법

### 1. 이미지 빌드 (인터넷 필요)

로컬에서 빌드 + Docker Hub 푸시:

```bash
podman login docker.io                   # 최초 1회

./1_build_image.sh                       # Python 3.13 (기본), build + push
./1_build_image.sh --no-push             # Python 3.13 로컬 빌드만

PYVER=3.12 ./1_build_image.sh            # Python 3.12 build + push
PYVER=3.12 ./1_build_image.sh --no-push  # Python 3.12 로컬 빌드만
```

또는 main 브랜치에 푸시하면 GitHub Actions 가 자동으로 3.12 / 3.13 모두 빌드/푸시.
GitHub Secrets 에 `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` 등록 필요.

### 2. 사내망에서 컨테이너 기동

```bash
# _latest 는 가변 태그라 옛 캐시가 남아 있을 수 있으니 항상 최신을 받는다.
docker pull joelkim/pypi:py313win_latest

docker run -d \
  --name pypi \
  -p 8080:8080 \
  --pull=always \
  --restart unless-stopped \
  joelkim/pypi:py313win_latest
```

> **주의 — `_latest` 캐시 함정**
> `_latest` 는 가변 태그다. 사내 서버에 예전 `_latest` 이미지가 캐시돼 있으면
> `docker run` 이 새로 push 된 이미지를 받지 않고 옛것을 그대로 띄운다.
> "빌드 로그엔 패키지가 보이는데 컨테이너 `/data/packages` 는 비어 있다" 면
> 십중팔구 이 경우다. `docker pull` 로 강제로 최신을 받거나, 날짜 태그
> (`py313win_YYYYMMDD`) 를 쓰면 확실하다.

또는 (PYVER 미지정 시 3.13 기본):

```bash
./2_run_container.sh                       # py313win_latest
PYVER=3.12 ./2_run_container.sh            # py312win_latest
PORT=9000 PYVER=3.12 ./2_run_container.sh  # 9000 포트, Python 3.12
```

### 3. 클라이언트(개발자 PC)에서 사용

**일회성:**

```bash
pip install --index-url http://<host>:8080/simple/ --trusted-host <host> <package>
```

**영구 설정 — Windows** (`%APPDATA%\pip\pip.ini`):

```ini
[global]
index-url = http://<host>:8080/simple/
trusted-host = <host>
```

브라우저로 `http://<host>:8080/` 접속 시 패키지 목록 확인 가능.

> Python 3.12 클라이언트는 `py312win_latest` 컨테이너에,
> Python 3.13 클라이언트는 `py313win_latest` 컨테이너에 붙도록 운영하면 된다.
> 한 호스트에서 둘 다 띄우려면 `PORT` 환경변수로 포트를 분리해 별도 컨테이너로 기동.

---

## 패키지 추가/변경

1. `requirements.txt` 수정 (버전 pin 권장)
2. main 브랜치에 푸시 → Actions 가 3.12 / 3.13 모두 새로 빌드/푸시
3. 사내 서버에서 `docker pull joelkim/pypi:py313win_latest && ./2_run_container.sh`

> **주의 — wheel 없는 패키지**
> Windows wheel 이 없으면 `download_packages.sh` 가 sdist 로 폴백한다.
> sdist 만 있는 패키지는 Windows 클라이언트에서 설치 시 컴파일러 등 빌드 도구가
> 필요할 수 있다. 가능하면 wheel 이 제공되는 버전으로 pin 하는 것이 안정적.

> **의존성 해결 — Windows 환경 마커 기준**
> 빌드 컨테이너는 Linux 이지만, `download_packages.sh` 의 Phase 0 은
> `uv pip compile --python-platform windows --python-version <버전>` 으로
> **Windows 환경 마커**(`sys_platform == "win32"` 등)를 평가해 의존성을 해결한다.
> 따라서 Windows 에서만 필요한 의존성(예: `poetry → keyring → pywin32-ctypes`,
> `colorama`, `pywin32` …)도 빠짐없이 미러에 포함된다.
> 반대로 Linux/macOS 전용 의존성(`uvloop` 등)은 Windows 해결 그래프에 애초에
> 등장하지 않으므로 자동으로 배제된다 — 별도 제외 목록이 필요 없다.
>
> (과거에는 Linux 기준 `pip download` 로 해결해 `pywin32-ctypes` 같은 Windows
> 전용 의존성이 통째로 누락되는 문제가 있었다. 현재는 해결됨.)

> **주의 — 다운로드 불가 패키지 (안전망)**
> Windows 해결 그래프에 들어오면서도 PyPI 에 Windows wheel/sdist 가 아예 없어
> 다운로드 자체가 실패하는 패키지가 생기면, `download_packages.sh` 의
> `SKIP_PACKAGES` 배열에 등록하면 빌드 실패에서 제외된다. Windows 마커 해결
> 덕분에 이 목록은 보통 비어 있어도 된다.

---

## 추가 패키지를 런타임에 얹기 (선택)

이미지에 박힌 패키지 외에 호스트의 wheel 디렉터리도 같이 서빙하려면 바인드 마운트:

```bash
docker run -d --name pypi -p 8080:8080 \
  -v /host/extra-wheels:/data/extra:ro \
  joelkim/pypi:py313win_latest \
  pypi-server run -p 8080 -i 0.0.0.0 -a . -P . /data/packages /data/extra
```
