#!/usr/bin/env bash
#
# Builds a custom MobileVLCKit.xcframework with `access_output_livehttp`
# (libvlc's HLS segmenter) restored to the iOS module list. The stock
# CocoaPods pod strips it — this script removes the strip.
#
# Time budget on an M1/M2 (8-core) Mac:
#   First build (device arm64 + simulator arm64):  90-135 min
#   Incremental rebuild (skips contribs):           5-10 min
#   Device-only build (EXTRA_FLAGS=-v):            60-90 min
#
# The default builds BOTH slices (device arm64 + simulator arm64) via
# the -f flag passed to buildMobileVLCKit.sh. Both slices are required
# to run the app on the simulator; CocoaPods refuses to link a slice-less
# variant. Override EXTRA_FLAGS if you only need one.
#
# Produces:
#   vendor/MobileVLCKit/MobileVLCKit.xcframework   (with ios-arm64 and
#                                                   ios-arm64-simulator)
#   vendor/MobileVLCKit/MobileVLCKit.podspec
#
# Wire the Podfile to consume the vendor pod:
#   pod 'MobileVLCKit', :path => 'vendor/MobileVLCKit'
#
# A thin wrapper (scripts/ensure-mobilevlckit.sh) runs this automatically
# on `pod install` when either slice is missing.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Consumers (Cast.app via a submodule wrapper) can redirect both the
# scratch dir and the install dir away from this repo by exporting
# CAST_BUILD_ROOT / CAST_OUT_DIR. Defaults reproduce the original
# stand-alone behaviour: artefacts land inside this checkout.
BUILD_ROOT="${CAST_BUILD_ROOT:-${REPO_ROOT}/.build/vlckit}"
OUT_DIR="${CAST_OUT_DIR:-${REPO_ROOT}/vendor/MobileVLCKit}"
VLCKIT_BRANCH="${VLCKIT_BRANCH:-3.0}"
ARCH_FLAG="${ARCH_FLAG:--a aarch64}"
EXTRA_FLAGS="${EXTRA_FLAGS:--v -f}"

mkdir -p "${BUILD_ROOT}"
mkdir -p "${OUT_DIR}"

if [[ ! -d "${BUILD_ROOT}/VLCKit" ]]; then
  git clone --depth=1 --branch "${VLCKIT_BRANCH}" \
    https://code.videolan.org/videolan/VLCKit.git \
    "${BUILD_ROOT}/VLCKit"
fi

cd "${BUILD_ROOT}/VLCKit"

# Patch: drop the `output_livehttp` blacklist entry and pass --enable-sout.
# We apply the patch idempotently — re-running the script is a no-op if
# the patch is already in place.
PATCH_MARKER="# LIVEHTTP_RESTORED"
if ! grep -q "${PATCH_MARKER}" buildMobileVLCKit.sh 2>/dev/null; then
  echo "[build-mvk] Patching buildMobileVLCKit.sh to un-blacklist livehttp"
  # 1) Remove `output_livehttp` from the VLC plugin blacklist. The
  #    blacklist lives in a shell variable concatenated across many
  #    lines of the script; we filter it with sed rather than a
  #    structured edit so the patch survives minor upstream drift.
  sed -i.bak -E \
    -e 's/[[:space:]]*output_livehttp[[:space:]]*/ /g' \
    buildMobileVLCKit.sh
  # 2) Ensure libvlc configure gets --enable-sout. The script's
  #    configure invocation typically passes --disable-sout inside a
  #    CONFIGURE_FLAGS-like block. Replace it.
  sed -i.bak2 -E \
    -e 's/--disable-sout/--enable-sout/g' \
    buildMobileVLCKit.sh
  echo "${PATCH_MARKER}" >> buildMobileVLCKit.sh
fi

# The gcrypt contrib is required if you want AES-128 segment encryption
# (`--enable-livehttp-crypt`). We skip it by default — unencrypted HLS
# works for LAN casting. To enable: export WANT_GCRYPT=1 before running.
if [[ "${WANT_GCRYPT:-0}" == "1" ]]; then
  echo "[build-mvk] Adding libgcrypt contrib (for livehttp-crypt)"
  # shellcheck disable=SC2016
  sed -i.bak3 -E 's/--disable-gcrypt/--enable-gcrypt/g' buildMobileVLCKit.sh || true
fi

# Force autoconf to mark pipe2 as unavailable. pipe2 is a Linux-only
# syscall; iOS SDK 26 does not declare it, but the autoconf probe
# falsely detects it on aarch64 simulator hosts. Injecting
# `export ac_cv_func_pipe2=no` into the same block where
# buildMobileVLCKit.sh already forces other iOS-only symbols is the
# standard autoconf override path. Idempotent.
BMVK="${BUILD_ROOT}/VLCKit/buildMobileVLCKit.sh"
# Xcode 27 cannot archive the upstream iOS 9 framework target. Cast targets
# iOS 26+, so use the modern toolchain's supported floor for both slices.
if grep -q '^SDK_MIN=9.0$' "${BMVK}"; then
  sed -i.cast-sdk-min 's/^SDK_MIN=9.0$/SDK_MIN=15.0/' "${BMVK}"
fi
if ! grep -q 'ac_cv_func_pipe2=no' "${BMVK}"; then
  echo "[build-mvk] Injecting ac_cv_func_pipe2=no override into buildMobileVLCKit.sh"
  python3 - "${BMVK}" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
marker = 'export ac_cv_func_timespec_get=no'
if marker not in text:
    sys.exit("WARNING: timespec_get marker missing — buildMobileVLCKit.sh diverged")
insertion = (
    marker + '\n\n'
    '    # pipe2() is Linux-only — iOS SDK 26 does not declare it and the\n'
    '    # autoconf probe falsely detects it on aarch64 simulator hosts.\n'
    '    export ac_cv_func_pipe2=no'
)
text = text.replace(marker, insertion, 1)
path.write_text(text)
PY
fi

# Patch the simulator-branch plugin-collection path. In the simulator
# module-removal loop (around line 1022), the script does
# `spushd $arch/lib/vlc/plugins`, but `$arch` is the VLC arch name
# (aarch64) while the on-disk directory is `arm64`. Every other
# filesystem reference in the script uses `$actual_arch` which applies
# the aarch64→arm64 mapping; this one line slipped through. Without
# this fix, the build dies with `pushd: aarch64/lib/vlc/plugins: No
# such file or directory` whenever BUILD_SIMULATOR=yes and the
# configured arch resolves to aarch64 (i.e. `-a aarch64 -f` on Apple
# Silicon). Idempotent marker: SIMARCH_FIX.
SIMARCH_MARKER="# SIMARCH_FIX"
if ! grep -q "${SIMARCH_MARKER}" "${BMVK}" 2>/dev/null; then
  echo "[build-mvk] Patching simulator-branch plugin path to use actual_arch"
  sed -i.bak5 -E \
    -e 's|spushd \$arch/lib/vlc/plugins|spushd $actual_arch/lib/vlc/plugins|' \
    "${BMVK}"
  echo "${SIMARCH_MARKER}" >> "${BMVK}"
fi

# Dedup VLCMODULES after both plugin-collection branches run. The device
# branch (line ~971) and the simulator branch (line ~1022) each append
# every plugin .a filename they find, without coordinating. For plugins
# that exist in BOTH install-iPhoneOS/arm64 and install-iPhoneSimulator/
# arm64 (the vast majority), the name lands in VLCMODULES twice. That
# list feeds DEVICELDFLAGS which feeds OTHER_LIBTOOLFLAGS for the
# StaticLibVLC target — libtool then merges each plugin .a into
# libStaticLibVLC.a twice, and the final framework link fails with ~48
# duplicate-symbol errors (ios.o, bonjour.o, audiounit_ios.o, etc.).
# Inject an awk-based dedup just after the simulator-install block and
# before contribs are collected. Idempotent marker: VLCMODULES_DEDUP.
DEDUP_MARKER="# VLCMODULES_DEDUP"
if ! grep -q "${DEDUP_MARKER}" "${BMVK}" 2>/dev/null; then
  echo "[build-mvk] Injecting VLCMODULES dedup after plugin collection"
  python3 - "${BMVK}" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
anchor = '        spopd # vlc-install-"$OSSTYLE"Simulator\n    fi\n\n    spushd libvlc/vlc\n'
if anchor not in text:
    sys.exit("WARNING: VLCMODULES_DEDUP anchor missing — buildMobileVLCKit.sh diverged")
dedup = (
    '        spopd # vlc-install-"$OSSTYLE"Simulator\n'
    '    fi\n'
    '\n'
    '    # VLCMODULES_DEDUP: device + simulator branches both append to\n'
    '    # VLCMODULES; shared plugins end up twice and cause ~48 duplicate-\n'
    '    # symbol linker errors when StaticLibVLC runs libtool.\n'
    '    VLCMODULES=$(echo "$VLCMODULES" | tr \' \' \'\\n\' | awk \'NF && !seen[$0]++\' | tr \'\\n\' \' \')\n'
    '\n'
    '    spushd libvlc/vlc\n'
)
text = text.replace(anchor, dedup, 1)
path.write_text(text)
PY
fi

# Apply the core patches after upstream has cloned/reset/patched libvlc,
# before either architecture compiles. This also runs with -n, which skips
# network/source-reset steps for an incremental build. Forward and reverse
# checks make repeated runs safe and fail clearly if upstream has diverged.
export CAST_LIBVLC_PATCH_DIR="${REPO_ROOT}/patches"
if ! grep -q '# CAST_CORE_PATCHES' "${BMVK}"; then
  echo "[build-mvk] Installing post-source-setup libvlc patch hook"
  python3 - "${BMVK}" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
anchor = 'spopd\n\n#\n# Build time\n#\n'
if text.count(anchor) != 1:
    sys.exit('ERROR: libvlc patch hook anchor missing or ambiguous')
hook = '''spopd

# CAST_CORE_PATCHES: keep the canonical source fixes in both slices.
for cast_core_patch in "${CAST_LIBVLC_PATCH_DIR:?Canonical patch directory is required}"/*.patch; do
    if git -C "${VLCROOT}" apply --reverse --check "${cast_core_patch}" >/dev/null 2>&1; then
        continue
    fi
    git -C "${VLCROOT}" apply --check "${cast_core_patch}"
    git -C "${VLCROOT}" apply "${cast_core_patch}"
done

#
# Build time
#
'''
path.write_text(text.replace(anchor, hook, 1))
PY
fi

# The contrib Makefile regenerates its compiler/SDK variables on every run,
# but toolchain.cmake has no prerequisites and survives Xcode switches.
# Invalidate only generated CMake configuration when its compiler or SDK
# differs from the environment selected for this architecture. Keep source,
# installed libraries, and unchanged-toolchain incremental caches intact.
if ! grep -q '# CAST_CMAKE_TOOLCHAIN_REFRESH' "${BMVK}"; then
  echo "[build-mvk] Installing per-architecture CMake toolchain refresh"
  python3 - "${BMVK}" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
anchor = '    make fetch -j$MAKE_JOBS\n'
if text.count(anchor) != 1:
    sys.exit('ERROR: contrib toolchain refresh anchor missing or ambiguous')
hook = '''    # CAST_CMAKE_TOOLCHAIN_REFRESH
    if [ -f toolchain.cmake ] && {
        ! grep -Fqx -- "set(CMAKE_C_COMPILER ${CC})" toolchain.cmake ||
        ! grep -Fqx -- "set(CMAKE_CXX_COMPILER ${CXX})" toolchain.cmake ||
        ! grep -Fqx -- "set(CMAKE_OSX_SYSROOT ${SDKROOT})" toolchain.cmake;
    }; then
        info "Refreshing cached CMake configuration for ${OSSTYLE}${PLATFORM} ${ARCH}"
        rm -f toolchain.cmake
        for cast_cmake_build in */_build; do
            [ -d "${cast_cmake_build}" ] || continue
            rm -f "${cast_cmake_build}/CMakeCache.txt"
            rm -rf "${cast_cmake_build}/CMakeFiles"
        done
    fi
    make fetch -j$MAKE_JOBS
'''
path.write_text(text.replace(anchor, hook, 1))
PY
fi

# Meson has a separate generated compiler cross-file. Its only prerequisite
# is the generator script, so Xcode switches also leave this file stale.
# Use a separate marker to upgrade cached builds that already have the
# CMake refresh hook. Meson recipes clear their own build configuration.
if ! grep -q '# CAST_MESON_TOOLCHAIN_REFRESH' "${BMVK}"; then
  echo "[build-mvk] Installing per-architecture Meson toolchain refresh"
  python3 - "${BMVK}" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
anchor = '    make fetch -j$MAKE_JOBS\n'
if text.count(anchor) != 1:
    sys.exit('ERROR: contrib Meson refresh anchor missing or ambiguous')
hook = '''    # CAST_MESON_TOOLCHAIN_REFRESH
    if [ -f crossfile.meson ] && {
        ! grep -Fqx -- "c = '${CC}'" crossfile.meson ||
        ! grep -Fqx -- "cpp = '${CXX}'" crossfile.meson ||
        ! grep -Fqx -- "ar = '${AR}'" crossfile.meson ||
        ! grep -Fqx -- "strip = '${STRIP}'" crossfile.meson;
    }; then
        info "Refreshing cached Meson toolchain for ${OSSTYLE}${PLATFORM} ${ARCH}"
        rm -f crossfile.meson
    fi
    make fetch -j$MAKE_JOBS
'''
path.write_text(text.replace(anchor, hook, 1))
PY
fi

# Wipe stale config.h so configure re-runs with the new override, and
# nuke any existing filesystem.lo caches so make re-compiles with
# HAVE_PIPE2 undefined.
if ! grep -q '# CAST_CORE_CONFIGURE_REFRESH' "${BMVK}"; then
  echo "[build-mvk] Correcting the core configure refresh condition"
  python3 - "${BMVK}" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = '    if [ "${VLCROOT}/configure" -nt config.log -o \\\n         "${THIS_SCRIPT_PATH}" -nt config.log ]; then\n'
new = '''    # CAST_CORE_CONFIGURE_REFRESH: THIS_SCRIPT_PATH was never defined.
    # The canonical wrapper removes config.h to require current configuration.
    if [ ! -f config.h -o "${VLCROOT}/configure" -nt config.log -o \\
         "${ROOT_DIR}/buildMobileVLCKit.sh" -nt config.log ]; then
'''
if text.count(old) != 1:
    sys.exit('ERROR: core configure condition missing or ambiguous')
path.write_text(text.replace(old, new, 1))
PY
fi

find "${BUILD_ROOT}/VLCKit/libvlc/vlc/build-"* -name config.h -delete 2>/dev/null || true
find "${BUILD_ROOT}/VLCKit/libvlc/vlc/build-"* -name "filesystem.lo" -delete 2>/dev/null || true
find "${BUILD_ROOT}/VLCKit/libvlc/vlc/build-"* -name "filesystem.o" -delete 2>/dev/null || true

echo "[build-mvk] Starting VLCKit compile (branch=${VLCKIT_BRANCH}, ${ARCH_FLAG})"
# Two-pass build: configure+make may fail on the iOS simulator's
# mis-detected HAVE_PIPE2 (pipe2 is Linux-only but the autoconf probe
# reports it present on aarch64 macOS hosts). We run once — if config.h
# claims HAVE_PIPE2 we patch it and re-enter make, which picks up where
# it left off.
set +e
time ./buildMobileVLCKit.sh ${EXTRA_FLAGS} ${ARCH_FLAG}
STATUS=$?
set -e

for CFG in \
  "${BUILD_ROOT}/VLCKit/libvlc/vlc/build-iPhoneSimulator/arm64/config.h" \
  "${BUILD_ROOT}/VLCKit/libvlc/vlc/build-iPhoneOS/arm64/config.h" ; do
  if [[ -f "${CFG}" ]] && grep -q '^#define HAVE_PIPE2 1' "${CFG}"; then
    echo "[build-mvk] Patching mis-detected HAVE_PIPE2 in ${CFG}"
    sed -i.bak 's|^#define HAVE_PIPE2 1|/* #undef HAVE_PIPE2 */ /* patched: pipe2 is Linux-only */|' "${CFG}"
    STATUS=99  # force retry below
  fi
done

if [[ "${STATUS}" -ne 0 ]]; then
  echo "[build-mvk] Resuming build after config.h patch"
  time ./buildMobileVLCKit.sh ${EXTRA_FLAGS} ${ARCH_FLAG}
fi

PRODUCT="${BUILD_ROOT}/VLCKit/build/MobileVLCKit.xcframework"
if [[ ! -d "${PRODUCT}" ]]; then
  echo "[build-mvk] ERROR: ${PRODUCT} not produced. Build failed." >&2
  exit 1
fi

echo "[build-mvk] Verifying livehttp symbol is present in each slice"
# Pick the Mach-O framework binary, not the dSYM companion. Two files named
# `MobileVLCKit` exist per slice: `…/MobileVLCKit.framework/MobileVLCKit`
# (the binary we want) and `…/dSYMs/…/DWARF/MobileVLCKit` (debug info). The
# dSYM doesn't always carry the plugin symbol, so an unfiltered `find` that
# happens to pick it first produces a false-negative verify.
SLICE_BINS=()
while IFS= read -r -d '' bin; do
  SLICE_BINS+=("$bin")
done < <(find "${PRODUCT}" \
  -path '*/MobileVLCKit.framework/MobileVLCKit' \
  -not -path '*dSYM*' \
  -type f -print0)
if [[ ${#SLICE_BINS[@]} -eq 0 ]]; then
  echo "[build-mvk] ERROR: no MobileVLCKit.framework binary found under ${PRODUCT}." >&2
  exit 1
fi
# VLC mangles the static-plugin entry point as
# `vlc_entry__<category>_lib<plugin_lib_name>`, so the livehttp symbol
# surfaces as `vlc_entry__access_output_libaccess_output_livehttp`.
#
# Two-stage check: (1) nm for the entry-point symbol, (2) strings for
# the raw plugin name as a defense-in-depth backup (the plugin name is
# embedded as a C string literal by libvlc's set_shortname metadata
# and survives even aggressive stripping).
#
# The output is captured into shell variables and matched with `case`
# globs — NOT piped into `grep -q`. With `set -o pipefail` at the top
# of this script, `nm -a BIN | grep -q PATTERN` returns 141 on a hit:
# grep exits after the first match, nm writes its next chunk (dylibs
# here have ~80k symbols, far more than the 64KB pipe buffer), gets
# SIGPIPE, and pipefail surfaces that as the pipeline status. The
# `if` then takes the else branch even though the symbol is present.
# That was the cause of an observed false-negative verify.
verify_livehttp_slice() {
  local bin="$1"
  local nm_err nm_out strings_out
  nm_err=$(mktemp)
  nm_out=$(nm -a "$bin" 2>"$nm_err" || true)
  case "$nm_out" in
    *vlc_entry__access_output_lib*livehttp*)
      rm -f "$nm_err"
      return 0
      ;;
  esac
  strings_out=$(strings -a "$bin" 2>/dev/null || true)
  case "$strings_out" in
    *access_output_livehttp*)
      echo "[build-mvk] note: nm missed the symbol; strings fallback" \
           "confirmed livehttp in ${bin}" >&2
      rm -f "$nm_err"
      return 0
      ;;
  esac
  if [[ -s "$nm_err" ]]; then
    echo "[build-mvk] nm stderr for ${bin}:" >&2
    sed 's/^/[build-mvk]   /' "$nm_err" >&2
  fi
  rm -f "$nm_err"
  return 1
}

for SLICE_BIN in "${SLICE_BINS[@]}"; do
  if verify_livehttp_slice "${SLICE_BIN}"; then
    echo "[build-mvk] OK: livehttp entry present in ${SLICE_BIN}"
  else
    echo "[build-mvk] ERROR: livehttp symbol not found in ${SLICE_BIN}." >&2
    echo "[build-mvk] The patch did not restore the module. Inspect the" >&2
    echo "[build-mvk] sed edits in buildMobileVLCKit.sh and retry." >&2
    exit 1
  fi
done

echo "[build-mvk] Copying xcframework to ${OUT_DIR}"
rm -rf "${OUT_DIR}/MobileVLCKit.xcframework"
cp -R "${PRODUCT}" "${OUT_DIR}/MobileVLCKit.xcframework"
python3 "${REPO_ROOT}/scripts/build-provenance.py" "${OUT_DIR}" --record

cat > "${OUT_DIR}/MobileVLCKit.podspec" <<'EOF'
Pod::Spec.new do |s|
  s.name         = 'MobileVLCKit'
  s.version      = '3.6.0-livehttp'
  s.summary      = 'MobileVLCKit custom build with access_output_livehttp restored.'
  s.description  = <<-DESC
    Stock CocoaPods pod strips `access_output_livehttp`, which libvlc
    needs for its HLS segmenter. This fork is produced by
    scripts/build-mobilevlckit-with-livehttp.sh in the Cast app repo and
    re-enables that module (plus --enable-sout), with the documented
    presentation-only stream-output timestamp correction.
  DESC
  s.homepage     = 'https://code.videolan.org/videolan/VLCKit'
  s.license      = { :type => 'LGPL-2.1+' }
  s.authors      = { 'VideoLAN' => 'vlc@videolan.org' }
  s.platform     = :ios, '11.0'
  s.source       = { :http => 'file:///dev/null' }
  s.vendored_frameworks = 'MobileVLCKit.xcframework'
end
EOF

echo "[build-mvk] Done. Update Podfile:"
echo "    pod 'MobileVLCKit', :path => 'vendor/MobileVLCKit'"
echo "    (then: pod install)"
