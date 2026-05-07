#!/usr/bin/env bash
#
# Idempotent check: verifies that vendor/MobileVLCKit.xcframework has
# both the device (ios-arm64) and simulator (ios-arm64-simulator) slices.
# Runs scripts/build-mobilevlckit-with-livehttp.sh only if either slice
# is missing. Cheap (a few `test -d` calls) when already present — safe
# to invoke from the Podfile or a pre-build step.
#
# Exit codes:
#   0 — both slices present (no-op) OR build completed successfully
#   1 — build was required and failed
#
# Force a rebuild even if both slices are present:
#   FORCE_REBUILD=1 scripts/ensure-mobilevlckit.sh
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCF="${REPO_ROOT}/vendor/MobileVLCKit/MobileVLCKit.xcframework"
DEVICE_SLICE="${XCF}/ios-arm64/MobileVLCKit.framework/MobileVLCKit"
SIM_SLICE="${XCF}/ios-arm64-simulator/MobileVLCKit.framework/MobileVLCKit"

need_build=0
if [[ "${FORCE_REBUILD:-0}" == "1" ]]; then
  echo "[ensure-mvk] FORCE_REBUILD=1 — rebuilding xcframework"
  need_build=1
elif [[ ! -f "${DEVICE_SLICE}" ]]; then
  echo "[ensure-mvk] Missing device slice: ${DEVICE_SLICE#${REPO_ROOT}/}"
  need_build=1
elif [[ ! -f "${SIM_SLICE}" ]]; then
  echo "[ensure-mvk] Missing simulator slice: ${SIM_SLICE#${REPO_ROOT}/}"
  need_build=1
fi

if [[ "${need_build}" -eq 0 ]]; then
  echo "[ensure-mvk] OK: device + simulator slices present"
  exit 0
fi

cat >&2 <<EOF
[ensure-mvk] MobileVLCKit.xcframework needs to be (re)built.
[ensure-mvk] First build takes 90–135 min; incremental is 5–10 min.
[ensure-mvk] Running: scripts/build-mobilevlckit-with-livehttp.sh
EOF

exec bash "${REPO_ROOT}/scripts/build-mobilevlckit-with-livehttp.sh"
