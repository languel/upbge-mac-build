#!/bin/bash
# UPBGE build script for Apple Silicon (resilient to retries).
# Re-running is safe — it skips already-completed phases.
# All output -> <repo-root>/build.log
# Status sentinel -> <repo-root>/build.status

set -u  # leave -e off so we can log failures cleanly

ROOT="${UPBGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$ROOT/upbge"
BUILD_DIR="$ROOT/build_darwin"
LOG="$ROOT/build.log"
STATUS_FILE="$ROOT/build.status"
PHASE_FILE="$ROOT/build.phase"

# Make Homebrew tools discoverable.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$PATH"

mark_phase() {
    local phase="$1"
    echo "$phase" > "$PHASE_FILE"
    echo "===== [$(date '+%H:%M:%S')] PHASE: $phase =====" | tee -a "$LOG"
}

write_status() {
    local s="$1"
    local msg="$2"
    printf '%s\n%s\n%s\n' "$s" "$(date)" "$msg" > "$STATUS_FILE"
}

on_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        # Only overwrite status with generic message if we don't already have a specific one.
        if ! grep -q '^FAILED\|^SUCCESS' "$STATUS_FILE" 2>/dev/null; then
            write_status "FAILED" "Script exited with code $rc during phase: $(cat "$PHASE_FILE" 2>/dev/null || echo unknown)"
        fi
    fi
}
trap on_exit EXIT

# Reset status — but keep the log so monitoring sees the full history of attempts.
rm -f "$STATUS_FILE"

{
    echo ""
    echo "==========================================================="
    echo "UPBGE build attempt at $(date)"
    echo "Source: $SRC | Build: $BUILD_DIR | PID: $$"
    echo "==========================================================="
} >> "$LOG" 2>&1

# -------- Phase 0: prerequisites + install missing build tools --------------
mark_phase "0_prereqs"
{
    xcode-select -p
    clang --version | head -1
    cmake --version | head -1
} >> "$LOG" 2>&1

for tool in cmake git python3 clang; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        write_status "FAILED" "Missing required tool: $tool"
        exit 1
    fi
done

# Ensure Homebrew is present
if ! command -v brew >/dev/null 2>&1; then
    write_status "FAILED" "Homebrew not found — install brew first: https://brew.sh"
    exit 1
fi

# Install ninja + ccache if missing
need_install=()
command -v ninja  >/dev/null 2>&1 || need_install+=("ninja")
command -v ccache >/dev/null 2>&1 || need_install+=("ccache")
if [[ ${#need_install[@]} -gt 0 ]]; then
    echo "Installing missing build tools: ${need_install[*]}" >> "$LOG"
    brew install "${need_install[@]}" >> "$LOG" 2>&1
    brew_rc=$?
    if [[ $brew_rc -ne 0 ]]; then
        write_status "FAILED" "brew install ${need_install[*]} failed (rc=$brew_rc)"
        exit $brew_rc
    fi
fi

# Verify they are now on PATH
{
    echo "ninja:  $(command -v ninja  && ninja --version)"
    echo "ccache: $(command -v ccache && ccache --version | head -1)"
} >> "$LOG" 2>&1

cd "$SRC" || { write_status "FAILED" "Cannot cd to $SRC"; exit 1; }

# -------- Phase 1: make update (skip if libs already present) ----------------
mark_phase "1_make_update"
libs_stale=$(cd "$SRC" && git submodule status lib/macos_arm64 2>/dev/null | grep -c '^+' || true)
if [[ -d "$SRC/lib/macos_arm64" ]] && [[ -n "$(ls -A "$SRC/lib/macos_arm64" 2>/dev/null)" ]] && [[ "$libs_stale" == "0" ]]; then
    lib_size=$(du -sh "$SRC/lib/macos_arm64" 2>/dev/null | cut -f1)
    echo "lib/macos_arm64 already populated ($lib_size) and current — skipping libs update" >> "$LOG"
else
    echo "Updating precompiled libs (first fetch is ~2-5 GB, updates are smaller)..." >> "$LOG"
    # --no-blender: never touch the source checkout (CI pins a SHA / local tree
    # is managed by the user). Fetches only the precompiled libraries.
    python3 "$SRC/build_files/utils/make_update.py" --no-blender --architecture arm64 >> "$LOG" 2>&1
    update_rc=$?
    if [[ $update_rc -ne 0 ]]; then
        write_status "FAILED" "make update failed with rc=$update_rc"
        exit $update_rc
    fi
fi

# -------- Phase 2: configure & build -----------------------------------------
mark_phase "2_build"

# If a stale partial build dir exists without a CMakeCache, scrub it.
if [[ -d "$BUILD_DIR" && ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    rm -rf "$BUILD_DIR"
fi

ccache --max-size=20G >> "$LOG" 2>&1 || true

# Build using the documented fast path. CMake will autodetect arm64 + Apple clang.
make ninja ccache BUILD_DIR="$BUILD_DIR" >> "$LOG" 2>&1
build_rc=$?
if [[ $build_rc -ne 0 ]]; then
    tail_excerpt=$(tail -25 "$LOG" | tr '\n' '|' | cut -c1-1500)
    write_status "FAILED" "build failed rc=$build_rc; tail: $tail_excerpt"
    exit $build_rc
fi

# -------- Phase 3: locate output ---------------------------------------------
mark_phase "3_locate"
APP=""
for candidate in \
    "$BUILD_DIR/bin/Blender.app" \
    "$BUILD_DIR/bin/UPBGE.app" \
    "$BUILD_DIR/bin/Release/Blender.app" \
    "$BUILD_DIR/bin/Release/UPBGE.app"; do
    if [[ -d "$candidate" ]]; then APP="$candidate"; break; fi
done
{
    echo "Build dir bin contents:"
    ls -la "$BUILD_DIR/bin" 2>&1 | head -30
    echo "Located app bundle: ${APP:-<not found>}"
} >> "$LOG"

if [[ -z "$APP" ]]; then
    write_status "FAILED" "build completed but no .app bundle found in $BUILD_DIR/bin"
    exit 1
fi

# -------- Phase 4: smoke-test -------------------------------------------------
mark_phase "4_smoke_test"
EXE="$APP/Contents/MacOS/Blender"
[[ -x "$EXE" ]] || EXE="$APP/Contents/MacOS/UPBGE"
if [[ ! -x "$EXE" ]]; then
    write_status "FAILED" "no executable inside $APP/Contents/MacOS"
    exit 1
fi

VERSION_FILE="$ROOT/build.version"
echo "--- $EXE --version ---" >> "$LOG"
"$EXE" --version > "$VERSION_FILE" 2>> "$LOG"
ver_rc=$?
cat "$VERSION_FILE" >> "$LOG"
if [[ $ver_rc -ne 0 ]]; then
    write_status "FAILED" "$EXE --version exited with rc=$ver_rc"
    exit $ver_rc
fi

VERSION_LINE=$(head -1 "$VERSION_FILE")

# -------- Phase 5: bundle uplogic into the bundled Python --------------------
# bge_netlogic (Logic Nodes) needs the `uplogic` PyPI package. By default it
# pip-installs at runtime on first use; we pre-install it here so the addon
# works offline and on first launch. Idempotent — re-runs upgrade in place.
mark_phase "5_bundle_uplogic"
PY=""
for candidate in \
    "$APP/Contents/Resources/5.2/python/bin/python3.13" \
    "$APP/Contents/Resources/5.2/python/bin/python3.12" \
    "$APP/Contents/Resources/5.2/python/bin/python3.11"; do
    if [[ -x "$candidate" ]]; then PY="$candidate"; break; fi
done
# Fallback: pick any python3.* the bundled python ships (in case Python is bumped)
if [[ -z "$PY" ]]; then
    PY=$(ls "$APP/Contents/Resources"/*/python/bin/python3.* 2>/dev/null | head -1)
fi

if [[ -n "$PY" && -x "$PY" ]]; then
    {
        echo "Bundling uplogic via $PY"
        "$PY" -m ensurepip --upgrade
        "$PY" -m pip install --upgrade uplogic
    } >> "$LOG" 2>&1
    uplogic_rc=$?
    if [[ $uplogic_rc -ne 0 ]]; then
        # Don't fail the whole build over this — Logic Nodes will fall back to
        # runtime auto-install. Just record the warning.
        echo "WARNING: uplogic bundling failed (rc=$uplogic_rc) — addon will install at runtime instead." >> "$LOG"
    else
        echo "uplogic bundled OK." >> "$LOG"
    fi
else
    echo "WARNING: could not locate bundled python under $APP/Contents/Resources — skipping uplogic bundle." >> "$LOG"
fi

mark_phase "6_done"
write_status "SUCCESS" "App: $APP | Exec: $EXE | Version: $VERSION_LINE"
echo "===== BUILD SUCCESS at $(date) =====" >> "$LOG"
exit 0
