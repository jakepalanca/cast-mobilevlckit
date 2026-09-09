# cast-mobilevlckit

LGPL-2.1 source artifact for the custom `MobileVLCKit.xcframework` embedded in [Cast.app](https://github.com/jakepalanca/Cast) on the iOS App Store.

This repository exists to satisfy GNU LGPL-2.1 §4 + §6 ("provide the source / make relinking possible") for distributing a modified libVLC binary in a code-signed iOS application. It contains:

- The exact build script Cast.app's vendored `MobileVLCKit.xcframework` was produced from — `scripts/build-mobilevlckit-with-livehttp.sh`
- A pin of the upstream `videolan/VLCKit` commit the script was applied to — `UPSTREAM.lock`
- A human-readable description of every patch — `PATCHES.md`
- The stream-output timestamp correction — `patches/0001-sout-convert-presentation-only-timestamps.patch`
- The libebur128 CMake recipe correction — `patches/0002-contrib-libebur128-use-shared-cmake-build-directory.patch`
- The full text of the GNU Lesser General Public License version 2.1 — `LICENSE`

## What was changed

The stock CocoaPods `MobileVLCKit` pod is built with `access_output_livehttp` (libvlc's HLS segmenter) stripped from the iOS plugin list. Cast.app uses that module to serve converted HLS to receivers. Our build script restores it, enables stream output, and applies build fixes for iOS on Apple Silicon. A narrow libvlc source patch also converts presentation-only timestamps before stream output, fixing FLV clock discontinuities. See `PATCHES.md` for the full list and source provenance.

**No license-incompatible code is enabled.** The build does not pull in `x264`, `x265`, `faac`, `fdk-aac`, or any `--enable-gpl` / `--enable-nonfree` flag. The resulting binary remains LGPL-2.1-or-later, identical in license terms to upstream VLCKit.

## Reproducing the build

Requirements:

- macOS 14+ on Apple Silicon
- Xcode 15+ with the iOS 17 SDK or newer
- ~30 GB free disk
- 90–135 minutes for a clean first build (5–10 min incremental)

```bash
git clone https://github.com/jakepalanca/cast-mobilevlckit.git
cd cast-mobilevlckit
bash scripts/build-mobilevlckit-with-livehttp.sh
```

The script clones the configured `videolan/VLCKit` branch when no checkout exists, applies the patches described in `PATCHES.md`, runs the upstream `buildMobileVLCKit.sh`, and verifies the `vlc_entry__access_output_lib*livehttp*` symbol in each resulting slice. For the recorded build, use the revision in `UPSTREAM.lock`; the script does not automatically check out that revision. `PATCHES.md` includes the incremental command for the verified cached checkout.

Output: `vendor/MobileVLCKit/MobileVLCKit.xcframework` containing `ios-arm64` and `ios-arm64-simulator` slices.

## Relinking Cast.app against a modified libVLC

LGPL-2.1 §4 grants you the right to substitute your own modified version of libVLC into Cast.app. To exercise this:

1. Modify `videolan/VLCKit` and/or `videolan/vlc` as you wish.
2. Build a new `MobileVLCKit.xcframework` using the recipe above.
3. Drop your xcframework into Cast.app's `vendor/MobileVLCKit/` and rebuild Cast.app from source.

If for any reason you cannot reproduce the build from source, the maintainer will provide pre-built object files for the released binary on request — see Cast.app's in-app *Settings → Acknowledgments* screen for the contact mailto.

## Upstream

| Component | Upstream | Pinned |
| --- | --- | --- |
| VLCKit | <https://code.videolan.org/videolan/VLCKit> | branch `3.0` @ the commit in `UPSTREAM.lock` |
| libVLC | <https://code.videolan.org/videolan/vlc> | submodule, pinned by the VLCKit commit above |

To inspect upstream changes since the pinned commit (after running the build once):

```bash
git -C .build/vlckit/VLCKit log --oneline $(awk -F'= ' '/^commit/ {print $2}' UPSTREAM.lock)..HEAD
```

## License

libVLC, VLCKit, and all patches in this repository are licensed under the GNU Lesser General Public License version 2.1 or later. The full text lives in `LICENSE`. © VideoLAN and contributors.

## Trademark

"VLC" and the traffic-cone logo are trademarks of VideoLAN. This project is not affiliated with or endorsed by VideoLAN. libVLC is consumed strictly under its LGPL-2.1+ license; no upstream branding is redistributed.
