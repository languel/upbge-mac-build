#!/bin/bash
# UPBGE — sign + notarize + DMG packaging pipeline.
#
# Usage:
#   ./package_dmg.sh                           # signs from build_darwin/bin, no notarize
#   ./package_dmg.sh --notarize                # signs + submits to Apple + staples
#   ./package_dmg.sh --source /Applications    # use already-installed copy
#   ./package_dmg.sh --version 0.53-edu         # custom version label in DMG name (default: derived from source, e.g. 0.53-alpha-macos-arm64-<date>)
#   ./package_dmg.sh --dmg-only                # skip staging+signing, just rebuild DMG
#                                              # (use after a create-dmg AppleScript hiccup)
#   ./package_dmg.sh --plain-dmg               # skip create-dmg's Finder dance entirely
#
# Auth (for --notarize):
#   Preferred: keychain profile  (xcrun notarytool store-credentials UPBGE_NOTARY)
#   Fallback : env vars          (NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx ./package_dmg.sh --notarize)
#              optional override : NOTARY_APPLE_ID, NOTARY_TEAM_ID
#
# Prerequisites (one-time):
#   1. Developer ID Application certificate installed in Keychain.
#      Apple Developer → Certificates → "+" → Developer ID Application → Download → double-click.
#   2. (only if --notarize)  brew install create-dmg   # for polished DMG layout
#   3. (only if --notarize)  xcrun notarytool store-credentials UPBGE_NOTARY
#         Apple ID:        your apple id email
#         Team ID:         shown by `security find-identity -v -p codesigning`
#         App-spec passwd: from appleid.apple.com → App-Specific Passwords
#      The script reads from the keychain profile name "UPBGE_NOTARY" — do NOT change it.
#
# What it does:
#   1. Auto-detects your Developer ID Application identity.
#   2. Stages a fresh copy of Blender.app + Blenderplayer.app into ./dist/staging.
#   3. Strips quarantine xattrs and resigns every nested .dylib/.so/.framework
#      (codesign --deep is unreliable for Python C extensions).
#   4. Signs the appex, the player, then the main app — outermost-last.
#   5. (--notarize) Zips each .app, submits to notarytool, waits, staples.
#   6. Builds DMG with create-dmg (or hdiutil fallback).
#   7. Signs and (optionally) notarizes the DMG itself.

set -e
set -o pipefail

# -------- args --------
SOURCE_DIR=""
DO_NOTARIZE=0
VERSION=""   # default derived from the source tree below; override with --version
KEYCHAIN_PROFILE="UPBGE_NOTARY"
DMG_ONLY=0
PLAIN_DMG=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize) DO_NOTARIZE=1; shift;;
        --source)   SOURCE_DIR="$2"; shift 2;;
        --version)  VERSION="$2"; shift 2;;
        --profile)  KEYCHAIN_PROFILE="$2"; shift 2;;
        --dmg-only) DMG_ONLY=1; shift;;
        --plain-dmg) PLAIN_DMG=1; shift;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

cd "$(dirname "$0")"
ROOT="${UPBGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

# -------- default version: upstream naming, e.g. 0.53-alpha-macos-arm64-2026-06-10
if [[ -z "$VERSION" ]]; then
    VER_H="$ROOT/upbge/source/blender/blenkernel/BKE_blender_version.h"
    if [[ -f "$VER_H" ]]; then
        ver() { grep -m1 "#define $1 " "$VER_H" | awk '{print $3}'; }
        VERSION="0.$(ver UPBGE_VERSION)-$(ver UPBGE_VERSION_CYCLE)-macos-arm64-$(date +%Y-%m-%d)"
    else
        VERSION="macos-arm64-$(date +%Y-%m-%d)"
        echo "[warn] $VER_H not found — using generic version label $VERSION"
    fi
fi

# -------- locate source apps --------
if [[ -z "$SOURCE_DIR" ]]; then
    if [[ -d "$ROOT/build_darwin/bin/Blender.app" ]]; then
        SOURCE_DIR="$ROOT/build_darwin/bin"
    elif [[ -d "/Applications/Blender.app" ]]; then
        echo "[info] No build_darwin/bin/Blender.app — falling back to /Applications/Blender.app"
        SOURCE_DIR="/Applications"
    else
        echo "ERROR: cannot find Blender.app. Re-run build.sh, or pass --source <dir>" >&2
        exit 1
    fi
fi

BLENDER_SRC="$SOURCE_DIR/Blender.app"
PLAYER_SRC="$SOURCE_DIR/Blenderplayer.app"

[[ -d "$BLENDER_SRC" ]] || { echo "ERROR: $BLENDER_SRC missing" >&2; exit 1; }
[[ -d "$PLAYER_SRC"  ]] || { echo "WARN: $PLAYER_SRC missing — DMG will only contain Blender.app"; }

# -------- detect signing identity --------
IDENTITY=$(security find-identity -v -p codesigning | \
    awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
    cat >&2 <<'EOF'
ERROR: no "Developer ID Application" certificate found in your default keychain.

Fix:
  1. Open https://developer.apple.com/account/resources/certificates/list
  2. + → "Developer ID Application" → follow the CSR steps in Keychain Access.
  3. Download the .cer and double-click it.
  4. Re-run this script.

If you already have it but it's in another keychain, run:
  security list-keychains -d user
to see which keychains are searched.
EOF
    exit 1
fi
TEAM_ID=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\).*/\1/')
echo "[ok] Signing identity: $IDENTITY"
echo "[ok] Team ID: $TEAM_ID"

# -------- paths --------
DIST="$ROOT/dist"
STAGE="$DIST/staging"
DMG="$DIST/upbge-${VERSION}.dmg"
VOLNAME="UPBGE ${VERSION%%-macos-arm64*}"
ENTITLEMENTS="$ROOT/upbge/release/darwin/entitlements.plist"
THUMB_ENTITLEMENTS="$ROOT/upbge/release/darwin/thumbnailer_entitlements.plist"
BACKGROUND="$ROOT/upbge/release/darwin/background_extended.tif"
# Generated by extend_dmg_background.py — rescaled from the 1080x700 upstream
# original to 1440x960 to fill our 720x480 pt window at retina @2x.
# Optional (needs Pillow; --plain-dmg never uses it): a missing background
# just means create-dmg lays out a window without artwork.
if [[ "$PLAIN_DMG" -eq 0 && ! -f "$BACKGROUND" ]]; then
    python3 "$ROOT/scripts/extend_dmg_background.py" || \
        echo "[warn] could not generate DMG background (Pillow missing?) — continuing without it"
fi

[[ -f "$ENTITLEMENTS" ]]       || { echo "ERROR: $ENTITLEMENTS missing"; exit 1; }
[[ -f "$THUMB_ENTITLEMENTS" ]] || { echo "ERROR: $THUMB_ENTITLEMENTS missing"; exit 1; }

# -------- stage fresh copies (never sign in place) --------
if [[ "$DMG_ONLY" -eq 1 && -d "$STAGE/Blender.app" ]]; then
    echo "[stage] --dmg-only: reusing existing $STAGE (skipping copy + signing)"
else
    echo "[stage] Refreshing $STAGE"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$BLENDER_SRC" "$STAGE/Blender.app"
    [[ -d "$PLAYER_SRC" ]] && cp -R "$PLAYER_SRC" "$STAGE/Blenderplayer.app"

    # Clear any quarantine bits left from prior launches.
    xattr -cr "$STAGE"
fi

# -------- sign helpers --------
sign_one() {
    local target="$1"
    local entitle="${2:-}"
    local extra=()
    [[ -n "$entitle" ]] && extra+=(--entitlements "$entitle")
    codesign --force --timestamp --options runtime \
        --sign "$IDENTITY" \
        "${extra[@]}" \
        "$target"
}

# Sign every loose Mach-O inside an app bundle — Python .so files,
# embedded dylibs, frameworks, etc. codesign --deep is known to skip
# nested bundles that don't have an Info.plist.
sign_inside() {
    local app="$1"
    echo "[sign-inner] $app"
    # innermost first: .dylib, .so, then frameworks
    find "$app" -type f \( -name "*.dylib" -o -name "*.so" \) \
        -exec codesign --force --timestamp --options runtime \
                       --sign "$IDENTITY" {} +
    # frameworks (signed as bundles)
    find "$app" -type d -name "*.framework" | while read -r fw; do
        sign_one "$fw"
    done
    # any nested executables in MacOS dirs other than the main one
    find "$app/Contents/Resources" -type f -perm +111 2>/dev/null | while read -r exe; do
        if file "$exe" | grep -q "Mach-O"; then
            codesign --force --timestamp --options runtime \
                     --sign "$IDENTITY" "$exe" || true
        fi
    done
}

# -------- sign Blender.app --------
BLENDER_APP="$STAGE/Blender.app"
PLAYER_APP="$STAGE/Blenderplayer.app"
THUMB_APPEX="$BLENDER_APP/Contents/PlugIns/blender-thumbnailer.appex"

if [[ "$DMG_ONLY" -eq 0 ]]; then
    sign_inside "$BLENDER_APP"

    # Thumbnailer appex — must be signed with sandbox entitlements BEFORE the outer Blender.app.
    if [[ -d "$THUMB_APPEX" ]]; then
        echo "[sign] $THUMB_APPEX"
        sign_one "$THUMB_APPEX" "$THUMB_ENTITLEMENTS"
    fi

    echo "[sign] $BLENDER_APP"
    sign_one "$BLENDER_APP" "$ENTITLEMENTS"

    # -------- sign Blenderplayer.app --------
    if [[ -d "$PLAYER_APP" ]]; then
        sign_inside "$PLAYER_APP"
        echo "[sign] $PLAYER_APP"
        sign_one "$PLAYER_APP" "$ENTITLEMENTS"
    fi

    # -------- verify signatures --------
    echo "[verify] strict signature check"
    codesign --verify --deep --strict --verbose=2 "$BLENDER_APP"
    [[ -d "$PLAYER_APP" ]] && codesign --verify --deep --strict --verbose=2 "$PLAYER_APP"
else
    echo "[sign] skipped (--dmg-only)"
fi

# -------- notarize (optional) --------
# Auth selection: keychain profile is the default; if NOTARY_PASSWORD is set in
# env, we fall back to inline credentials (handy when notarytool's keychain
# storage is misbehaving on your system).
notary_auth_args() {
    if [[ -n "${NOTARY_PASSWORD:-}" ]]; then
        echo "--apple-id ${NOTARY_APPLE_ID:?set NOTARY_APPLE_ID to your Apple ID email}"
        echo "--team-id  ${NOTARY_TEAM_ID:-$TEAM_ID}"
        echo "--password $NOTARY_PASSWORD"
    else
        echo "--keychain-profile $KEYCHAIN_PROFILE"
    fi
}

# Submit to Apple and wait for a terminal result, tolerant of transient network
# errors. `notarytool submit --wait` aborts the whole run if the long status poll
# hits a network blip (e.g. "The Internet connection appears to be offline",
# NSURLErrorDomain -1009) even though the upload succeeded — so we submit once,
# capture the submission id, then poll `info` ourselves and only fail on a real
# terminal Invalid/Rejected verdict.
notarize_submit_wait() {
    local file="$1" subid status i submit_rc submit_out submit_msg submit_err retry_delay
    local max_retry_delay=30
    for i in $(seq 1 5); do
        submit_err=$(mktemp "${TMPDIR:-/tmp}/upbge-notary-submit.XXXXXX")
        # shellcheck disable=SC2046
        submit_out=$(xcrun notarytool submit "$file" $(notary_auth_args) --output-format json 2>"$submit_err")
        submit_rc=$?
        submit_msg=$(cat "$submit_err" 2>/dev/null || true)
        rm -f "$submit_err"
        subid=$(printf '%s' "$submit_out" \
            | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
        if [[ -n "$subid" ]]; then
            break
        fi
        [[ -n "$submit_msg" ]] || submit_msg="$submit_out"
        submit_msg=$(printf '%s' "$submit_msg" | tr '\n' ' ' | tr -s '[:space:]' ' ')
        if [[ -n "${NOTARY_PASSWORD:-}" ]]; then
            submit_msg=$(SUBMIT_MSG="$submit_msg" NOTARY_PASSWORD="$NOTARY_PASSWORD" python3 - <<'PY'
import os
print(os.environ["SUBMIT_MSG"].replace(os.environ["NOTARY_PASSWORD"], "[redacted]"))
PY
)
        fi
        echo "[notarize] submit attempt $i failed (rc=$submit_rc): ${submit_msg:-no output}" >&2
        if [[ "$i" -eq 5 ]]; then
            echo "[notarize] giving up after repeated submit failures" >&2
            return 1
        fi
        case "$i" in
            1) retry_delay=5 ;;
            2) retry_delay=10 ;;
            3) retry_delay=20 ;;
            4) retry_delay=$max_retry_delay ;;
        esac
        echo "[notarize] retrying submit in ${retry_delay}s" >&2
        sleep "$retry_delay"
    done
    echo "[notarize] submission id: $subid — polling Apple (transient network errors retry)" >&2
    # ~40 min ceiling; Apple scans usually finish in 1–10 min.
    for i in $(seq 1 80); do
        # shellcheck disable=SC2046
        status=$(xcrun notarytool info "$subid" $(notary_auth_args) --output-format json 2>/dev/null \
                 | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
        case "$status" in
            Accepted) echo "[notarize] Accepted" >&2; return 0;;
            Invalid|Rejected)
                echo "[notarize] verdict: $status — fetching log" >&2
                # shellcheck disable=SC2046
                xcrun notarytool log "$subid" $(notary_auth_args) >&2 || true
                return 1;;
            "") echo "[notarize] poll $i: no response (transient) — retrying in 30s" >&2;;
            *)  echo "[notarize] poll $i: status=$status — waiting" >&2;;
        esac
        sleep 30
    done
    echo "[notarize] timed out waiting for Apple after retries" >&2
    return 1
}

notarize_app() {
    local app="$1"
    # If a notarization ticket is already stapled, skip — re-submitting wastes
    # 5+ minutes and Apple's scanners just produce the same Accepted result.
    if xcrun stapler validate "$app" >/dev/null 2>&1; then
        echo "[notarize] $app already stapled — skipping"
        return 0
    fi
    local zip="${app%.app}.zip"
    echo "[notarize] zipping $app"
    /usr/bin/ditto -c -k --keepParent "$app" "$zip"
    echo "[notarize] submitting $zip — this typically takes 1–10 minutes"
    notarize_submit_wait "$zip"
    echo "[notarize] stapling ticket to $app"
    xcrun stapler staple "$app"
    rm -f "$zip"
}

if [[ "$DO_NOTARIZE" -eq 1 ]]; then
    notarize_app "$BLENDER_APP"
    [[ -d "$PLAYER_APP" ]] && notarize_app "$PLAYER_APP"
fi

# -------- build DMG --------
mkdir -p "$DIST"
rm -f "$DMG"

build_plain_dmg() {
    echo "[dmg] hdiutil create -format UDZO"
    # Stage just the apps (not the whole staging dir, which has a .DS_Store etc).
    local src="$DIST/dmg-src"
    rm -rf "$src"; mkdir -p "$src"
    cp -R "$BLENDER_APP" "$src/"
    [[ -d "$PLAYER_APP" ]] && cp -R "$PLAYER_APP" "$src/"
    # Drag-target shortcut for /Applications — works without create-dmg's AppleScript magic.
    ln -s /Applications "$src/Applications"
    hdiutil create -volname "$VOLNAME" \
        -srcfolder "$src" \
        -ov -format UDZO \
        "$DMG"
    rm -rf "$src"
}

DMG_OK=0
if [[ "$PLAIN_DMG" -eq 0 ]] && command -v create-dmg >/dev/null 2>&1; then
    echo "[dmg] creating polished DMG with create-dmg"
    DMG_ARGS=(
        --volname "$VOLNAME"
        --window-pos 200 120
        --window-size 720 480
        --icon-size 96
        --icon "Blender.app" 180 200
        --app-drop-link 540 200
        --no-internet-enable
        --hdiutil-quiet
    )
    [[ -f "$BACKGROUND" ]] && DMG_ARGS+=(--background "$BACKGROUND")
    # Blenderplayer goes in a second row — give it real breathing room.
    [[ -d "$PLAYER_APP" ]] && DMG_ARGS+=(--icon "Blenderplayer.app" 360 360)

    DMG_SRC="$DIST/dmg-src"
    rm -rf "$DMG_SRC"; mkdir -p "$DMG_SRC"
    cp -R "$BLENDER_APP" "$DMG_SRC/"
    [[ -d "$PLAYER_APP" ]] && cp -R "$PLAYER_APP" "$DMG_SRC/"

    if create-dmg "${DMG_ARGS[@]}" "$DMG" "$DMG_SRC"; then
        DMG_OK=1
    else
        echo
        echo "[dmg] create-dmg failed (usually macOS Finder Automation timeout)."
        echo "      To fix the polished version: System Settings → Privacy & Security →"
        echo "      Automation → Terminal → enable 'Finder', then re-run."
        echo "      Falling back to plain hdiutil DMG so you have something to ship."
        echo
    fi
    rm -rf "$DMG_SRC"
fi

if [[ "$DMG_OK" -eq 0 ]]; then
    if [[ "$PLAIN_DMG" -eq 0 ]] && ! command -v create-dmg >/dev/null 2>&1; then
        echo "[dmg] create-dmg not installed — using plain hdiutil"
        echo "      brew install create-dmg  (for a polished installer)"
    fi
    build_plain_dmg
fi

[[ -f "$DMG" ]] || { echo "ERROR: DMG not produced" >&2; exit 1; }

# -------- sign + notarize the DMG --------
echo "[sign] $DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "$DO_NOTARIZE" -eq 1 ]]; then
    echo "[notarize] DMG"
    notarize_submit_wait "$DMG"
    xcrun stapler staple "$DMG"
fi

# -------- final report --------
echo
echo "=================================================="
echo "DONE: $DMG"
ls -lh "$DMG"
echo
echo "Smoke tests:"
echo "  spctl -a -t open --context context:primary-signature -v \"$DMG\""
echo "  codesign -dvv \"$BLENDER_APP\""
if [[ "$DO_NOTARIZE" -eq 0 ]]; then
    echo
    echo "(unnotarized — students will need to right-click → Open the first time)"
    echo "(re-run with --notarize once you've set up the keychain profile)"
fi
echo "=================================================="
