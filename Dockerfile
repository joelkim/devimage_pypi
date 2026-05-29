# syntax=docker/dockerfile:1.7

# Python 버전은 빌드 시 --build-arg PYTHON_VERSION=<x.y> 로 지정.
# 기본값은 3.13. 글로벌 ARG 는 FROM 의 이미지 태그에서 직접 사용 가능하지만
# RUN/ENV 등에서 쓰려면 각 스테이지 내에서 다시 `ARG PYTHON_VERSION` 선언이 필요.
ARG PYTHON_VERSION=3.13

# ==============================================================================
# Stage 1: 패키지 다운로더 (Windows x64 전용)
#   - Phase 0: `uv pip compile --python-platform windows` 로 의존성 그래프 해결.
#              빌드 컨테이너는 Linux 이지만 Windows 환경 마커로 평가하므로
#              pywin32-ctypes 등 Windows 전용 의존성도 빠짐없이 포함된다.
#   - Phase 1: 해결된 각 패키지에 대해 --platform win_amd64 wheel 다운로드.
#              (pure-Python wheel `py3-none-any` 도 여기서 매칭됨)
#   - Phase 2: Windows wheel 이 없는 패키지는 sdist (.tar.gz / .zip) 로 폴백.
#   - 빌드 컨테이너는 Linux 이지만 결과물(/wheels)에는 Windows 용 파일만 담긴다.
# ==============================================================================
FROM python:${PYTHON_VERSION}-slim AS downloader

ARG PYTHON_VERSION
ENV PYVER=${PYTHON_VERSION} \
    WHEELS=/wheels \
    REQ=/build/requirements.txt

WORKDIR /build
COPY requirements.txt download_packages.sh ./
RUN chmod +x download_packages.sh && \
    pip install --no-cache-dir --upgrade pip && \
    ./download_packages.sh

# ==============================================================================
# Stage 2: pypiserver 런타임
#   - /data/packages 디렉터리를 HTTP 로 서빙 (PEP 503 simple index)
#   - 인증 비활성화 (-a . -P .) — 사내망 익명 읽기 전용
#   - 모든 패키지는 이미지 내장 — 런타임에 외부 인터넷 불필요
# ==============================================================================
FROM python:${PYTHON_VERSION}-slim

ARG PYTHON_VERSION
LABEL org.opencontainers.image.source="https://github.com/joelkim/devimage_pypi" \
      org.opencontainers.image.description="오프라인 PyPI 서버 (pypiserver) — Python ${PYTHON_VERSION}, Windows x64 전용, wheel + sdist 내장" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="py${PYTHON_VERSION}"

ENV PYPI_PACKAGES_DIR=/data/packages \
    PYPI_PORT=8080 \
    PYPI_PYTHON_VERSION=${PYTHON_VERSION}

RUN pip install --no-cache-dir "pypiserver[passlib]" && \
    mkdir -p "${PYPI_PACKAGES_DIR}" && \
    rm -rf /root/.cache

COPY --from=downloader /wheels/ /data/packages/

EXPOSE 8080

# 컨테이너 헬스체크 — 30 초 간격으로 simple index 응답 확인
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/').status==200 else 1)" || exit 1

# -a . / -P .  -> 모든 동작에 대해 인증 비활성화
# -i 0.0.0.0   -> 모든 인터페이스 바인딩
CMD ["pypi-server", "run", "-p", "8080", "-i", "0.0.0.0", "-a", ".", "-P", ".", "/data/packages"]
