#!/usr/bin/env bash
#
# Idempotent check: verifies that ${CAST_OUT_DIR:-vendor/MobileVLCKit}
# contains a `MobileVLCKit.xcframework` with both the device (ios-arm64)
# and simulator (ios-arm64-simulator) slices, and that each slice was
# built with the `access_output_livehttp` plugin restored. Runs
# scripts/build-mobilevlckit-with-livehttp.sh only when something is
# missing. Cheap (a few `test -d` calls + one `nm` per slice) when
# already present — safe to invoke from a Podfile or pre-build step.
#
# Override the install dir from a consumer (Cast.app) via the same
# CAST_OUT_DIR env var honoured by build-mobilevlckit-with-livehttp.sh:
#
#   CAST_OUT_DIR=/path/to/Cast/vendor/MobileVLCKit \
#   CAST_BUILD_ROOT=/path/to/Cast/.build/vlckit \
#       bash scripts/ensure-mobilevlckit.sh
#
# Exit codes:
#   0 — both slices present with livehttp symbol (no-op)
#       OR build completed successfully
#   1 — build was required and failed
#
# Force a rebuild even if both slices are present:
#   FORCE_REBUILD=1 scripts/ensure-mobilevlckit.sh
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${CAST_OUT_DIR:-${REPO_ROOT}/vendor/MobileVLCKit}"
XCF="${OUT_DIR}/MobileVLCKit.xcframework"
DEVICE_SLICE="${XCF}/ios-arm64/MobileVLCKit.framework/MobileVLCKit"
SIM_SLICE="${XCF}/ios-arm64-simulator/MobileVLCKit.framework/MobileVLCKit"

# We require the `_vlc_entry__access_output_libaccess_output_livehttp`
# entry point to be statically linked into BOTH slices. Cast.app's
# AirPlay path needs livehttp to repackage non-MP4 progressive containers
# (WebM/MKV/AVI/FLV/TS) into HLS for AVPlayer. The stock CocoaPods pod
# strips this module; this build keeps it. If a stock pod ever gets
# hand-dropped into vendor/ this check forces a rebuild before the app
# silently fails on AirPlay at runtime.
LIVEHTTP_SYMBOL="_vlc_entry__access_output_libaccess_output_livehttp"

slice_has_livehttp() {
  local slice_path="$1"
  [[ -f "${slice_path}" ]] || return 1
  # `nm -a | grep -q` would SIGPIPE nm the moment grep matches; with
  # `pipefail` set globally, that propagates as a nonzero pipe rc and
  # makes a binary-with-the-symbol look symbol-less. Stash nm's output
  # to a tempfile and grep it instead.
  local nm_dump
  nm_dump="$(mktemp)" || return 1
  nm -a "${slice_path}" >"${nm_dump}" 2>/dev/null || { rm -f "${nm_dump}"; return 1; }
  if grep -q -- "${LIVEHTTP_SYMBOL}" "${nm_dump}"; then
    rm -f "${nm_dump}"
    return 0
  fi
  rm -f "${nm_dump}"
  return 1
}

need_build=0
need_reason=""
if [[ "${FORCE_REBUILD:-0}" == "1" ]]; then
  need_build=1
  need_reason="FORCE_REBUILD=1"
elif [[ ! -f "${DEVICE_SLICE}" ]]; then
  need_build=1
  need_reason="missing device slice ${DEVICE_SLICE}"
elif [[ ! -f "${SIM_SLICE}" ]]; then
  need_build=1
  need_reason="missing simulator slice ${SIM_SLICE}"
elif ! slice_has_livehttp "${DEVICE_SLICE}"; then
  need_build=1
  need_reason="device slice is missing ${LIVEHTTP_SYMBOL} (looks like the stock pod)"
elif ! slice_has_livehttp "${SIM_SLICE}"; then
  need_build=1
  need_reason="simulator slice is missing ${LIVEHTTP_SYMBOL} (looks like the stock pod)"
elif ! python3 "${REPO_ROOT}/scripts/build-provenance.py" "${OUT_DIR}"; then
  need_build=1
  need_reason="framework provenance is missing or stale; source fixes must be compiled into both slices"
fi

if [[ "${need_build}" -eq 0 ]]; then
  echo "[ensure-mvk] OK: device + simulator slices present at ${OUT_DIR}, livehttp symbol verified"
  exit 0
fi

cat >&2 <<EOF
[ensure-mvk] MobileVLCKit.xcframework needs to be (re)built — ${need_reason}.
[ensure-mvk] First build takes 90–135 min; incremental is 5–10 min.
[ensure-mvk] Running: $(dirname "$0")/build-mobilevlckit-with-livehttp.sh
EOF

exec bash "$(dirname "$0")/build-mobilevlckit-with-livehttp.sh"
