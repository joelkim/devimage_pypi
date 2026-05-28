#!/usr/bin/env bash
# 로컬 테스트용 컨테이너 기동 스크립트.
#
# 환경변수:
#   PYVER  — 대상 Python 버전 (기본 3.13). 이미지 태그 선택에 사용.
#   PORT   — 호스트 포트 (기본 8080).
#
# 사용법:
#   ./2_run_container.sh                       # joelkim/pypi:py313win_latest
#   PYVER=3.12 ./2_run_container.sh            # joelkim/pypi:py312win_latest
#   PORT=9000 ./2_run_container.sh             # 호스트 9000 번에 바인딩
#
# `--` 뒤의 추가 인자는 pypi-server 로 전달됨.

set -e
export MSYS_NO_PATHCONV=1

PYVER="${PYVER:-3.13}"
PORT="${PORT:-8080}"
PY_TAG="py$(echo "${PYVER}" | tr -d '.')win"
CONTAINER="pypi_${PY_TAG}"
IMAGE="joelkim/pypi:${PY_TAG}_latest"

# 기존 컨테이너 정리
podman stop  "${CONTAINER}" 2>/dev/null || true
podman rm -f "${CONTAINER}" 2>/dev/null || true

# 새 컨테이너 실행
podman run -d \
  --name "${CONTAINER}" \
  --restart unless-stopped \
  -p "${PORT}:8080" \
  "${IMAGE}" \
  "$@"

echo
echo "이미지:          ${IMAGE}"
echo "컨테이너:        ${CONTAINER}"
echo "PyPI 서버:       http://localhost:${PORT}/"
echo "Simple index:    http://localhost:${PORT}/simple/"
echo
echo "스모크 테스트:"
echo "  curl -fsS http://localhost:${PORT}/simple/ | head"
echo "  pip install --index-url http://localhost:${PORT}/simple/ --trusted-host localhost requests"
