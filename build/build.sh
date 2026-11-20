#!/usr/bin/env bash
# Fortress full build: fetch depot_tools, sync Chromium to the pinned tag,
# apply public patches, configure, and compile the stripped independent binary.
#
# Usage:  build/build.sh [workdir]
#   workdir defaults to ./.fortress-build (needs >=200 GiB free + many hours)
#
# Env: BUILD_JOBS (default 4); TMPDIR (must live on a real disk).
# Version and source revision are pinned by CHROMIUM_VERSION + chromium-source.json.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$REPO/.fortress-build}"
ARGS_FILE="$REPO/build/args.gn"
OUT="Fortress"
VER="$(cat "$REPO/CHROMIUM_VERSION")"
REVISION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$REPO/build/chromium-source.json")"
# Compilation is separate from the small source-compatibility gate.
export TMPDIR="${TMPDIR:-$WORK/tmp}"
mkdir -p "$WORK" "$TMPDIR"
# systemd services do not necessarily inherit login environment variables.
export HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORK/cache}"
export GOCACHE="${GOCACHE:-$WORK/go-cache}"
mkdir -p "$XDG_CACHE_HOME" "$GOCACHE"
FREE_KB="$(df -Pk "$WORK" | awk 'NR==2 { print $4 }')"
if (( FREE_KB < 200 * 1024 * 1024 )); then
  echo "Chromium builder requires at least 200 GiB free; available: $FREE_KB KiB" >&2
  exit 1
fi

echo "==> Fortress build | Chromium $VER | out/$OUT | workdir $WORK"

# 1. depot_tools
if [ ! -d "$WORK/depot_tools" ]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
fi
export PATH="$WORK/depot_tools:$PATH"

# 2. Fetch only the pinned tag instead of fetching today's main branch first.
mkdir -p "$WORK/chromium/src"
if [[ ! -f "$WORK/chromium/.gclient" ]]; then
  (cd "$WORK/chromium" && gclient config --unmanaged https://chromium.googlesource.com/chromium/src.git)
fi
if [[ ! -d "$WORK/chromium/src/.git" ]]; then
  git -C "$WORK/chromium/src" init
  git -C "$WORK/chromium/src" remote add origin https://chromium.googlesource.com/chromium/src.git
fi
cd "$WORK/chromium/src"
git fetch --depth 1 origin "refs/tags/$VER:refs/tags/$VER"
ACTUAL_REVISION="$(git rev-parse "tags/$VER^{commit}")"
if [[ "$ACTUAL_REVISION" != "$REVISION" ]]; then
  echo "Chromium tag moved: expected $REVISION, got $ACTUAL_REVISION" >&2
  exit 1
fi
git checkout --detach "$REVISION"
gclient sync -D --no-history

# 3. install build deps (first run; harmless to repeat)
./build/install-build-deps.sh --no-prompt --no-backwards-compatible
python3 "$REPO/tools/check_chromium_source.py" --source "$WORK/chromium/src"

# 4. apply Fortress patches
"$REPO/build/apply-patches.sh" "$WORK/chromium/src"

# 5. configure + build
"$WORK/chromium/src/buildtools/linux64/gn" gen "out/$OUT" --fail-on-unused-args --args="$(cat "$ARGS_FILE")"
# Set FORTRESS_STOP_AFTER_GN=1 to stop here (patched + configured), e.g. to compile
# only the patched files first as a quick check before the multi-hour full build.
if [[ -n "${FORTRESS_STOP_AFTER_GN:-}" ]]; then
  echo "==> Configured out/$OUT; stopping before compile (FORTRESS_STOP_AFTER_GN)"
  exit 0
fi
"$WORK/chromium/src/third_party/ninja/ninja" -j "${BUILD_JOBS:-4}" -C "out/$OUT" chrome chrome_crashpad_handler

echo "==> Done: $WORK/chromium/src/out/$OUT/chrome"
"$WORK/chromium/src/out/$OUT/chrome" --version
