#!/usr/bin/env bash
# Assemble the portable tilion-fortress/ bundle (extract-and-run, like a Chromium snapshot)
# and a .tar.gz. Bundles only the runtime files chrome needs + the fonts + launcher.
#
# Usage:  packaging/build-bundle.sh <out/Fortress dir> <fonts dir> <dest dir> [platform]
#   platform defaults to linux-x64; names the asset tilion-fortress-<platform>.tar.gz
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?out/Fortress dir}"; FONTS="${2:?fonts dir}"; DEST="${3:?dest dir}"; PLATFORM="${4:-linux-x64}"
# Fail before touching the destination when required build outputs are missing.
case "$PLATFORM" in linux-x64|linux-arm64) ;; *) echo "Unsupported bundle platform: $PLATFORM" >&2; exit 1 ;; esac
for f in chrome resources.pak icudtl.dat libEGL.so libGLESv2.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json locales/en-US.pak; do
  if [[ ! -s "$SRC/$f" ]]; then
    echo "Missing required runtime file: $SRC/$f" >&2
    exit 1
  fi
done
B="$DEST/tilion-fortress"
rm -rf "$B"; mkdir -p "$B/fonts"

# Runtime files (everything chrome needs; the rest of out/ is build junk).
RUNTIME=( chrome chrome_crashpad_handler
  chrome_100_percent.pak chrome_200_percent.pak headless_command_resources.pak resources.pak
  icudtl.dat snapshot_blob.bin v8_context_snapshot.bin
  libEGL.so libGLESv2.so libvk_swiftshader.so libVkICD_mock_icd.so libqt5_shim.so libqt6_shim.so
  libvulkan.so.1            # Chrome's Vulkan LOADER — REQUIRED; loads the SwiftShader ICD (no WebGL without it)
  vk_swiftshader_icd.json ) # Vulkan ICD manifest — REQUIRED so SwiftShader/WebGL initializes
for f in "${RUNTIME[@]}"; do
  [ -e "$SRC/$f" ] && cp -a "$SRC/$f" "$B/$f"
done
cp -a "$SRC/locales" "$B/locales"

# Size: strip ELF debug/unneeded symbols (~176 MB off chrome) + trim UI locale .paks to the
# ones we serve. Behavior is byte-identical (strip removes symbols, not code; locale paks are
# internal UI, not JS-visible). NOTE: archive the UNSTRIPPED chrome + a .debug symbol file
# (objcopy --only-keep-debug) BEFORE this, so field crashpad minidumps can be symbolicated.
# ELF-only — do NOT run on Windows (.pdb) / macOS bundles.
# Missing tools or failed stripping are build failures, with stderr preserved.
command -v strip >/dev/null
strip --strip-unneeded "$B/chrome"
if [[ -e "$B/chrome_crashpad_handler" ]]; then
  strip --strip-unneeded "$B/chrome_crashpad_handler"
fi
shopt -s nullglob
for so in "$B"/*.so "$B"/*.so.1; do
  strip --strip-unneeded "$so"
done
find "$B/locales" -type f -name '*.pak' ! -name 'en-US.pak' ! -name 'en-GB.pak' -delete

# Fonts + launcher + fontconfig template + README.
cp "$FONTS"/*.ttf "$B/fonts/"
cp "$REPO/packaging/persona.sh" "$B/persona.sh"
cp "$REPO/packaging/tilion" "$B/tilion"; chmod +x "$B/tilion"
cp "$REPO/packaging/fonts.conf.template" "$B/fonts/fonts.conf.template"
sed "s/@CHROMIUM_VERSION@/$(cat "$REPO/CHROMIUM_VERSION")/" \
  "$REPO/packaging/bundle-README.txt" > "$B/README.txt"
# BSD-3 clause 2 and the font licences require the notices to ship with binaries.
cp "$REPO/LICENSE" "$B/LICENSE"
cp "$REPO/NOTICE" "$B/NOTICE"

ASSET="tilion-fortress-${PLATFORM}.tar.gz"
( cd "$DEST" && tar czf "$ASSET" tilion-fortress )
# Append SHA256 so the SDK can verify the download (SHA256SUMS format: "<hash>  <asset>")
( cd "$DEST" && sha256sum "$ASSET" >> SHA256SUMS )
echo "==> bundle: $DEST/$ASSET ($(du -h "$DEST/$ASSET" | cut -f1))"
echo "==> checksum appended to $DEST/SHA256SUMS"
