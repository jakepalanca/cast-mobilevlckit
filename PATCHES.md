# Patches applied

Build-script edits live inside `scripts/build-mobilevlckit-with-livehttp.sh`; libvlc source patches live in `patches/`. Each edit is idempotent. The source patches run after upstream source setup and before either device or simulator compilation, including incremental builds with `-n`. Forward/reverse applicability checks reject incompatible source trees.

The timestamp patch was prepared against cached VLCKit `319ed2c0724e3d4c4d34889a62fef1ae269491bc` (the revision recorded in `UPSTREAM.lock`), with its patched libvlc tree at `61eafa317f`. The simulator framework from that cached tree was byte-identical to the existing vendored framework before rebuilding. A fresh clone still follows the configured `VLCKIT_BRANCH`; use the recorded revision when reproducing this build.

## 1. Restore `access_output_livehttp`

The stock `buildMobileVLCKit.sh` blacklists `output_livehttp` from the iOS plugin list. We strip the entry so the plugin compiles into the static framework. Without this, libvlc cannot segment a stream into HLS chunks, and Cast.app cannot serve repackaged HLS to AirPlay receivers.

License of `access_output_livehttp`: LGPL-2.1-or-later (see the file header at `modules/access_output/livehttp.c` upstream).

## 2. Enable `--enable-sout`

The stock script passes `--disable-sout` to libvlc's `configure`. The `livehttp` module depends on the stream-output framework (sout); flipping the flag is required for the patch above to do anything.

## 3. (Optional) Enable `--enable-gcrypt`

Gated on `WANT_GCRYPT=1`. Required only for AES-128 segment encryption (`--enable-livehttp-crypt`). Disabled by default; unencrypted HLS is sufficient for LAN casting and avoids pulling the libgcrypt contrib (~30 min build).

## 4. Autoconf override: `ac_cv_func_pipe2=no`

`pipe2()` is a Linux-only syscall; iOS SDK 26 does not declare it, but the autoconf probe falsely detects it as present on aarch64 simulator hosts. Without the override, libvlc's `filesystem.c` references an undeclared symbol and the simulator slice fails to link.

We inject `export ac_cv_func_pipe2=no` next to the existing `ac_cv_func_timespec_get=no` block — the standard autoconf-override path the upstream script already uses for other iOS-only symbols.

## 5. Simulator plugin path: `$arch` → `$actual_arch`

In the simulator-branch plugin-collection loop (around line 1022 of upstream `buildMobileVLCKit.sh`), the script does `spushd $arch/lib/vlc/plugins`. `$arch` is the VLC arch name (`aarch64`) but the on-disk directory uses the mapped platform name (`arm64`). Every other filesystem reference in the script uses `$actual_arch`, which applies the `aarch64`→`arm64` mapping; this one line slipped through. Without the fix the build dies with `pushd: aarch64/lib/vlc/plugins: No such file or directory`.

## 6. `VLCMODULES` dedup

The device branch (~line 971) and the simulator branch (~line 1022) of `buildMobileVLCKit.sh` each append every plugin `.a` filename to the shared `VLCMODULES` variable without coordinating. Plugins that exist in both slices land in the list twice. That list feeds `DEVICELDFLAGS`, which feeds `OTHER_LIBTOOLFLAGS` for the StaticLibVLC target — `libtool` then merges each duplicated `.a` twice into `libStaticLibVLC.a`, and the final framework link fails with ~48 duplicate-symbol errors (`ios.o`, `bonjour.o`, `audiounit_ios.o`, …).

We inject an `awk`-based dedup just after the simulator-install block and before the contribs step.

## 7. Convert presentation-only timestamps before stream output

`patches/0001-sout-convert-presentation-only-timestamps.patch` changes `src/input/decoder.c` inside `DecoderPlaySout`. If a packet has invalid/nonpositive DTS and valid PTS, it converts PTS independently through the existing input clock. Valid-DTS packets and packets with no valid timestamp retain their existing behavior. It leaves DTS invalid for the downstream muxer's existing fallback; it does not clamp timestamps or trim content.

This fixes a concrete FLV startup discontinuity: the fixture's container start time is 46 ms, while its first video DTS is 0 ms. After demux normalization, that packet has negative DTS and positive PTS. Previously, `DecoderFixTs` skipped both timestamps because its primary DTS was invalid. The TS muxer then used that first raw PTS, followed by system-clock timestamps on subsequent packets. HLS exposed the jump as a segment hundreds of thousands of seconds long; the HTTP relay could fail receiver startup.

Cast's real HTTP/HLS regressions inspect PES timestamps from the first completed HLS segment and HTTP relay, as well as finite playlist duration, completed nonempty segments, and `ENDLIST`. The full H.264/AAC converter remains in use; this correction applies before both conversion and remux output paths.

To rebuild the verified cached checkout without fetching or resetting sources, run from the Cast repository:

```sh
EXTRA_FLAGS='-v -f -n' ARCH_FLAG='-a aarch64' bash scripts/build-mobilevlckit-with-livehttp.sh
```

Both `ios-arm64` and `ios-arm64-simulator` slices are rebuilt. Do not add `-l`, which skips the libvlc compilation required by this patch.

## 8. Use the shared CMake build directory for libebur128

`patches/0002-contrib-libebur128-use-shared-cmake-build-directory.patch` updates only the libebur128 contrib recipe. The shared `CMAKE` macro already provides `-S libebur128 -B libebur128/_build`. The old recipe first changed into `libebur128`, incorrectly producing a doubled source path and stopping the framework rebuild. The correction uses the same configure/build/install helpers as adjacent contrib recipes; it preserves the dependency, static build configuration, and functionality.

## 9. Refresh generated CMake and Meson configuration after switching Xcode

The contrib `toolchain.cmake` target has no prerequisites. Regenerating `Makefile` and `config.mak` with the selected Xcode therefore leaves absolute compiler and SDK paths from the prior installation in that file. This blocked the Xcode 27 beta rebuild with a nonexistent Xcode 26.4 compiler path.

The build-script hook checks C/C++ compiler and SDK paths after each architecture's configuration is generated. On a mismatch, it removes only `toolchain.cmake` and generated CMake configuration under the dependency `_build` directories, allowing the existing rules to regenerate them. Matching caches, installed libraries, and dependency sources remain intact. The same hook covers device and simulator builds and respects the toolchain selected by the build environment.

Meson's generated `crossfile.meson` has the same issue: its prerequisite is the generator script, not the selected compiler. A companion hook compares C/C++ compiler, archiver, and strip paths and removes only a mismatching cross-file. Existing Meson recipes already clear their build directory before configuring. Its separate marker upgrades cached build scripts that already contain the CMake correction.

## 10. Refresh core configuration when its generated header is missing

The upstream core configure condition referenced `THIS_SCRIPT_PATH`, which was never assigned. Deleting `config.h` alone therefore did not force configuration; `make` could replay the old `config.status --recheck` with a removed Xcode installation's compiler path. The corrected condition also checks for a missing `config.h` and uses the actual build-script path for its modification-time check. This makes the existing header invalidation run configure with the active compiler/SDK before compilation. Dependency caches are unaffected.

## License of these patches

LGPL-2.1-or-later, matching upstream VLCKit. None of the patches enable a GPL-only encoder or library. The modified C block includes a dated modification notice; the complete patch and build hook are retained here alongside the build-script edits.
