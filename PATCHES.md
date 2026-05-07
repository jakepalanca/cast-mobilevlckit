# Patches applied

Every patch lives inside `scripts/build-mobilevlckit-with-livehttp.sh` as an idempotent `sed` or `python` edit against `videolan/VLCKit` at the commit pinned in `UPSTREAM.lock`. Re-running the script after the patches are in place is a no-op.

No upstream C source is modified — these are all mechanical build-script edits.

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

## License of these patches

LGPL-2.1-or-later, matching upstream VLCKit. None of the patches enable a GPL-only encoder or library, and the resulting binary remains LGPL-2.1-or-later. No third-party code is added; only the upstream build script is edited in place.
