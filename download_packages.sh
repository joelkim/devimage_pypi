#!/usr/bin/env bash
# 내장 PyPI 미러용 패키지 다운로드 스크립트 (Windows x64 전용).
#
# 동작 방식:
#   Phase 0 — 의존성 해결 (임시)
#       * `pip download -r requirements.txt` 를 임시 디렉터리에 실행하여
#         transitive 의존성까지 포함된 전체 패키지 목록을 얻는다.
#       * 빌드 컨테이너는 Linux 이지만 이 단계는 의존성 그래프 해결용일 뿐
#         최종 결과물에는 포함되지 않는다.
#
#   Phase 1 — Windows x64 wheel 다운로드
#       * 해결된 각 패키지에 대해
#         `--only-binary=:all: --python-version 3.13 --platform win_amd64`
#         로 wheel 을 받는다.
#       * pure-Python wheel(`*-py3-none-any.whl`) 도 이 단계에서 함께 매칭됨.
#
#   Phase 2 — sdist 폴백
#       * Windows wheel 이 없는 패키지에 대해 sdist (.tar.gz / .zip) 를 받는다.
#       * Windows 클라이언트는 설치 시 직접 빌드해야 하므로
#         빌드 도구(컴파일러, Python headers 등)가 필요할 수 있다.
#
#   SKIP_PACKAGES — Windows 미지원 패키지
#       * 설계상 Windows 를 지원하지 않는 패키지 (예: uvloop) 는 미리 제외.
#       * 정규화된 이름(소문자, [-_.] 을 - 로 통일) 기준 매칭.
#       * 빌드 실패에서도 제외되어 다른 패키지 수집은 계속된다.
#
# 결과: /wheels 에 Windows x64 클라이언트(Python 3.13)용 wheel + sdist 저장.

set -euo pipefail

WHEELS="${WHEELS:-/wheels}"
REQ="${REQ:-/build/requirements.txt}"
PYVER="${PYVER:-3.13}"
TMP_RESOLVE="$(mktemp -d)"
trap 'rm -rf "${TMP_RESOLVE}"' EXIT

# 구조적으로 Windows 를 지원하지 않는 패키지.
# (uvloop: Linux/macOS 전용. uvicorn[standard] 가 transitive 로 끌어오지만
#  Windows uvicorn 은 uvloop 을 import 하지 않으므로 미러에 없어도 무방.)
SKIP_PACKAGES=(
    "uvloop"
)

# 정규화: 소문자 + [-_.]+ 를 '-' 로 통일 (PEP 503)
normalize() {
    python3 -c "import re,sys; print(re.sub(r'[-_.]+','-',sys.argv[1]).lower())" "$1"
}

# SKIP_PACKAGES 미리 정규화
SKIP_NORM=()
for sp in "${SKIP_PACKAGES[@]}"; do
    SKIP_NORM+=("$(normalize "${sp}")")
done

is_skipped() {
    local norm
    norm="$(normalize "$1")"
    for sp in "${SKIP_NORM[@]}"; do
        if [[ "${norm}" == "${sp}" ]]; then
            return 0
        fi
    done
    return 1
}

mkdir -p "${WHEELS}"

echo "==> Phase 0: 의존성 그래프 해결 (임시)"
pip download --dest "${TMP_RESOLVE}" -r "${REQ}" >/dev/null

# 임시 디렉터리의 모든 파일에서 <name>==<version> 추출
SPECS=$(python3 - "${TMP_RESOLVE}" <<'PY'
import re, sys
from pathlib import Path

d = Path(sys.argv[1])
out = set()
for f in d.iterdir():
    n = f.name
    if n.endswith(".whl"):
        parts = n[:-4].split("-")
        out.add(f"{parts[0]}=={parts[1]}")
    elif n.endswith(".tar.gz"):
        m = re.match(r"(.+?)-([0-9][^-]*)\.tar\.gz$", n)
        if m:
            out.add(f"{m.group(1)}=={m.group(2)}")
    elif n.endswith(".zip"):
        m = re.match(r"(.+?)-([0-9][^-]*)\.zip$", n)
        if m:
            out.add(f"{m.group(1)}=={m.group(2)}")
print("\n".join(sorted(out)))
PY
)

echo "  해결된 패키지 수: $(echo "${SPECS}" | wc -l)"
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
