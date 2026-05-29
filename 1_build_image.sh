#!/usr/bin/env bash
# 로컬 빌드 + Docker Hub 푸시 (linux/amd64).
#
# 환경변수:
#   PYVER  — 대상 Python 버전 (기본 3.13). 예: PYVER=3.12
#
# 사용법:
#   ./1_build_image.sh                       # PYVER=3.13 (기본), build + push
#   ./1_build_image.sh --no-push             # 로컬 빌드만 (테스트용)
#   PYVER=3.12 ./1_build_image.sh            # Python 3.12 용 이미지 build + push
#   PYVER=3.12 ./1_build_image.sh --no-push  # Python 3.12 로컬 빌드만
#
# 태그 형식:
#   joelkim/pypi:py<PYVER 점 제거>win_<YYYYMMDD>
#   joelkim/pypi:py<PYVER 점 제거>win_latest
#
# 필요 사항: podman, `podman login docker.io` 사전 수행
# 빌드 단계에서 wheel 다운로드를 위해 빌드 호스트는 인터넷 필요.
# 결과 이미지는 자체 완결적 (오프라인 동작 가능).

set -e
exec > >(tee build.log) 2>&1

PYVER="${PYVER:-3.13}"
IMAGE="joelkim/pypi"
PY_TAG="py$(echo "${PYVER}" | tr -d '.')win"
DATE_TAG="${PY_TAG}_$(TZ=Asia/Seoul date +%Y%m%dT%H%M%S)"
LATEST_TAG="${PY_TAG}_latest"

echo "==> ${IMAGE}:${DATE_TAG} 빌드 시작 (Python ${PYVER}, linux/amd64)"
podman build --platform linux/amd64 \
  --build-arg PYTHON_VERSION="${PYVER}" \
  -t "${IMAGE}:${DATE_TAG}" \
  -t "${IMAGE}:${LATEST_TAG}" .

if [[ "${1:-}" == "--no-push" ]]; then
  echo "==> --no-push 지정됨, 푸시 생략"
  exit 0
fi

echo "==> ${IMAGE}:${DATE_TAG} 푸시"
podman push "${IMAGE}:${DATE_TAG}"   "docker://docker.io/${IMAGE}:${DATE_TAG}"
echo "==> ${IMAGE}:${LATEST_TAG} 푸시"
podman push "${IMAGE}:${LATEST_TAG}" "docker://docker.io/${IMAGE}:${LATEST_TAG}"

echo "==> 완료"
