#!/usr/bin/env bash
# 내장 PyPI 미러용 패키지 다운로드 스크립트 (Windows x64 전용).
#
# 동작 방식:
#   Phase 0 — 의존성 해결 (Windows 환경 마커 기준)
#       * `uv pip compile --python-platform windows --python-version <PYVER>` 로
#         requirements.txt 를 해결한다.
#       * 핵심: 빌드 컨테이너는 Linux 이지만, uv 가 **Windows 환경 마커**
#         (sys_platform == "win32" / platform_system == "Windows" 등) 를
#         평가하므로 Windows 에서만 필요한 의존성도 빠짐없이 포함된다.
#         (예: poetry → keyring → pywin32-ctypes, colorama, pywin32 ...)
#       * 과거 `pip download` 방식은 Linux 마커로 해결되어 Windows 전용
#         의존성(pywin32-ctypes 등)이 통째로 누락되는 버그가 있었다.
#       * 반대로 Linux/macOS 전용 의존성(uvloop 등)은 Windows 해결 그래프에
#         애초에 등장하지 않으므로 별도 제외가 필요 없다.
#
#   Phase 1 — Windows x64 wheel 다운로드
#       * 해결된 각 패키지에 대해
#         `--only-binary=:all: --python-version <PYVER> --platform win_amd64`
#         로 wheel 을 받는다.
#       * pure-Python wheel(`*-py3-none-any.whl`) 도 이 단계에서 함께 매칭됨.
#
#   Phase 2 — sdist 폴백
#       * Windows wheel 이 없는 패키지에 대해 sdist (.tar.gz / .zip) 를 받는다.
#       * Windows 클라이언트는 설치 시 직접 빌드해야 하므로
#         빌드 도구(컴파일러, Python headers 등)가 필요할 수 있다.
#
#   SKIP_PACKAGES — 안전망 (보통 비어 있음)
#       * Windows 해결 그래프에 등장하면서도 PyPI 에 Windows wheel/sdist 가
#         전혀 없어 다운로드 자체가 불가능한 패키지를 명시적으로 제외.
#       * 정규화된 이름(소문자, [-_.] 을 - 로 통일) 기준 매칭.
#       * 빌드 실패에서도 제외되어 다른 패키지 수집은 계속된다.
#       * Windows 마커 해결로 대부분의 플랫폼 전용 패키지는 자동 배제되므로
#         이 목록은 보통 비어 있어도 된다.
#
# 결과: /wheels 에 Windows x64 클라이언트(Python <PYVER>)용 wheel + sdist 저장.

set -euo pipefail

WHEELS="${WHEELS:-/wheels}"
REQ="${REQ:-/build/requirements.txt}"
PYVER="${PYVER:-3.13}"
TMP_RESOLVE="$(mktemp -d)"
RESOLVED="${TMP_RESOLVE}/resolved.txt"
trap 'rm -rf "${TMP_RESOLVE}"' EXIT

# 다운로드 자체가 불가능한 패키지를 위한 안전망 (보통 비어 있음).
# Windows 마커 해결 덕분에 플랫폼 전용 패키지(uvloop 등)는 자동 배제되므로
# 평상시엔 빈 배열이어도 무방하다. PyPI 에 Windows 배포 파일이 아예 없어
# 빌드가 실패하는 패키지가 새로 등장하면 여기에 추가한다.
SKIP_PACKAGES=(
)

# 정규화: 소문자 + [-_.]+ 를 '-' 로 통일 (PEP 503)
normalize() {
    python3 -c "import re,sys; print(re.sub(r'[-_.]+','-',sys.argv[1]).lower())" "$1"
}

# SKIP_PACKAGES 미리 정규화 (빈 배열 안전)
SKIP_NORM=()
for sp in "${SKIP_PACKAGES[@]:-}"; do
    [[ -z "${sp}" ]] && continue
    SKIP_NORM+=("$(normalize "${sp}")")
done

is_skipped() {
    local norm
    norm="$(normalize "$1")"
    for sp in "${SKIP_NORM[@]:-}"; do
        [[ -z "${sp}" ]] && continue
        if [[ "${norm}" == "${sp}" ]]; then
            return 0
        fi
    done
    return 1
}

mkdir -p "${WHEELS}"

# uv 확보 (의존성 해결용). 없으면 pip 로 설치.
if ! command -v uv >/dev/null 2>&1; then
    echo "==> uv 미설치 — pip 로 설치"
    pip install --no-cache-dir uv >/dev/null
fi

echo "==> Phase 0: 의존성 그래프 해결 (Windows 마커 / Python ${PYVER})"
# --python-platform windows: Windows 환경 마커로 평가 → Windows 전용 의존성 포함.
# --python-version: 대상 클라이언트 Python 버전에 맞는 그래프 해결.
uv pip compile "${REQ}" \
    --python-platform windows \
    --python-version "${PYVER}" \
    --no-header --no-annotate \
    --output-file "${RESOLVED}" >/dev/null

# resolved.txt 는 `name==version` 라인들. 주석/빈 줄 제거 후 SPECS 로.
SPECS=$(grep -vE '^\s*(#|$)' "${RESOLVED}" | sed 's/[[:space:]].*$//' | sort)

echo "  해결된 패키지 수: $(echo "${SPECS}" | grep -c '==' || true)"
if [[ ${#SKIP_PACKAGES[@]} -gt 0 ]]; then
    echo "  스킵 목록: ${SKIP_PACKAGES[*]}"
fi
echo ""
echo "==> Phase 1 & 2: 패키지별 Windows wheel → sdist 폴백"

wheel_ok=()
sdist_ok=()
skipped=()
failed=()
for spec in ${SPECS}; do
    pkg_name="${spec%%==*}"
    if is_skipped "${pkg_name}"; then
        echo "  ~ 스킵 (Windows 미지원): ${spec}"
        skipped+=("${spec}")
        continue
    fi
    # Phase 1: Windows x64 wheel 시도
    if pip download --dest "${WHEELS}" --only-binary=:all: --no-deps \
            --python-version "${PYVER}" \
            --platform win_amd64 \
            "${spec}" >/dev/null 2>&1; then
        echo "  + wheel: ${spec}"
        wheel_ok+=("${spec}")
        continue
    fi
    # Phase 2: sdist 폴백
    if pip download --dest "${WHEELS}" --no-binary=:all: --no-deps \
            "${spec}" >/dev/null 2>&1; then
        echo "  = sdist: ${spec}"
        sdist_ok+=("${spec}")
        continue
    fi
    echo "  ! 실패: ${spec} (Windows wheel 도 sdist 도 받을 수 없음)"
    failed+=("${spec}")
done

echo ""
echo "==> 요약"
echo "  ${WHEELS} 내 파일 수: $(ls -1 "${WHEELS}" | wc -l)"
echo "  전체 크기:           $(du -sh "${WHEELS}" | cut -f1)"
echo "  wheel 다운로드: ${#wheel_ok[@]} 개"
echo "  sdist 폴백:     ${#sdist_ok[@]} 개"
echo "  스킵:           ${#skipped[@]} 개"
if [[ ${#sdist_ok[@]} -gt 0 ]]; then
    echo "  - sdist 패키지 (Windows 클라이언트에서 빌드 도구 필요할 수 있음):"
    for s in "${sdist_ok[@]}"; do echo "      ${s}"; done
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
    echo "  - 스킵된 패키지 (Windows 미지원):"
    for s in "${skipped[@]}"; do echo "      ${s}"; done
fi
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "  실패한 패키지: ${#failed[@]} 개"
    for s in "${failed[@]}"; do echo "      ${s}"; done
    echo ""
    echo "  → 의도된 미지원이라면 SKIP_PACKAGES 에 추가하세요."
    exit 1
fi
