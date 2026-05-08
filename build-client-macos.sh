#!/usr/bin/env bash
# Native macOS build of the AdaptixC2 Qt6 client into a portable .app bundle
# (Apple Silicon / arm64). Output: ./AdaptixClient-dist/AdaptixClient.app
#
# Usage:
#   ./build-client-macos.sh             # build
#   ./build-client-macos.sh --clean     # wipe build dir first
#   ./build-client-macos.sh --dmg       # also produce a .dmg
#
# Requires: Homebrew with cmake, qt@6, openssl@3 installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/AdaptixC2/AdaptixClient"
BUILD_DIR="${SCRIPT_DIR}/build/macos"
DIST_DIR="${SCRIPT_DIR}/AdaptixClient-dist"
RES_DIR="${SRC_DIR}/Resources"
ICNS="${RES_DIR}/AdaptixClient.icns"
LOGO_PNG="${RES_DIR}/Logo.png"

DO_CLEAN=0
DO_DMG=0
for arg in "$@"; do
    case "$arg" in
        --clean) DO_CLEAN=1 ;;
        --dmg)   DO_DMG=1 ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *)
            echo "[!] Unknown flag: $arg" >&2
            echo "    Use --clean and/or --dmg, or -h for help." >&2
            exit 2 ;;
    esac
done

# ---- preflight ---------------------------------------------------------------

OS_ARCH="$(uname -sm)"
if [[ "$OS_ARCH" != "Darwin arm64" ]]; then
    echo "[!] This script targets Apple Silicon macOS only (got: $OS_ARCH)." >&2
    echo "    For Linux, use: docker compose --profile build-client up --build --abort-on-container-exit" >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "[!] Homebrew not found. Install from https://brew.sh and re-run." >&2
    exit 1
fi

missing=()
for pkg in cmake qt@6 openssl@3; do
    brew --prefix "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} )); then
    echo "[!] Missing Homebrew packages: ${missing[*]}" >&2
    echo "    Install with: brew install ${missing[*]}" >&2
    exit 1
fi

QT_PREFIX="${QT_PREFIX:-$(brew --prefix qt@6)}"
SSL_PREFIX="$(brew --prefix openssl@3)"
MACDEPLOYQT="${QT_PREFIX}/bin/macdeployqt"

if [[ ! -x "$MACDEPLOYQT" ]]; then
    echo "[!] macdeployqt not found at $MACDEPLOYQT" >&2
    exit 1
fi

# ---- apply macOS-bundle patch (auto-revert on exit) --------------------------
# AdaptixC2 is a submodule pinned to a specific upstream SHA. The macOS bundle
# block lives in patches/ rather than committed inside the submodule, so the
# submodule working tree stays clean across upstream bumps. Apply on entry,
# revert on exit (success or failure) via trap.

PATCH="${SCRIPT_DIR}/patches/adaptixclient-macos-bundle.patch"
ADAPTIX_REPO="${SCRIPT_DIR}/AdaptixC2"

if [[ -f "$PATCH" ]]; then
    if git -C "$ADAPTIX_REPO" apply --check "$PATCH" 2>/dev/null; then
        echo "[*] Applying $PATCH"
        git -C "$ADAPTIX_REPO" apply "$PATCH"
        trap 'git -C "$ADAPTIX_REPO" apply -R "$PATCH" 2>/dev/null || true' EXIT
    elif git -C "$ADAPTIX_REPO" apply --check -R "$PATCH" 2>/dev/null; then
        echo "[+] Patch already applied (dirty submodule); leaving as-is"
    else
        echo "[!] Patch $PATCH no longer applies — upstream CMakeLists.txt has drifted." >&2
        echo "    Resolve manually, regenerate the patch, then re-run." >&2
        exit 1
    fi
fi

# ---- icon (sips + iconutil) --------------------------------------------------

regen_icon() {
    [[ -f "$LOGO_PNG" ]] || { echo "[!] Logo.png missing at $LOGO_PNG"; return 1; }
    if [[ -f "$ICNS" && "$ICNS" -nt "$LOGO_PNG" ]]; then
        echo "[+] Icon up to date: $ICNS"
        return 0
    fi
    echo "[*] Generating $ICNS from Logo.png..."
    local set_dir
    set_dir="$(mktemp -d)/AdaptixClient.iconset"
    mkdir -p "$set_dir"
    for sz in 16 32 64 128 256 512; do
        sips -z "$sz" "$sz"   "$LOGO_PNG" --out "$set_dir/icon_${sz}x${sz}.png"      >/dev/null
        sips -z $((sz*2)) $((sz*2)) "$LOGO_PNG" --out "$set_dir/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$set_dir" -o "$ICNS"
    rm -rf "$(dirname "$set_dir")"
    echo "[+] Wrote $ICNS"
}
regen_icon

# ---- configure + build -------------------------------------------------------

if (( DO_CLEAN )); then
    echo "[*] Cleaning $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "[*] Configuring (Qt: $QT_PREFIX, OpenSSL: $SSL_PREFIX)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DCMAKE_PREFIX_PATH="${QT_PREFIX};${SSL_PREFIX}"

echo "[*] Building"
cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"

APP_BUILD="${BUILD_DIR}/AdaptixClient.app"
if [[ ! -d "$APP_BUILD" ]]; then
    echo "[!] Build did not produce $APP_BUILD." >&2
    echo "    Confirm the if(APPLE) MACOSX_BUNDLE patch is present in CMakeLists.txt." >&2
    exit 1
fi

# ---- bundle Qt frameworks + relocatable RPATHs -------------------------------

DEPLOY_ARGS=( "$APP_BUILD" -verbose=1 )
(( DO_DMG )) && DEPLOY_ARGS+=( -dmg )

echo "[*] Running macdeployqt"
"$MACDEPLOYQT" "${DEPLOY_ARGS[@]}"

# macdeployqt leaves the build-time rpath (/opt/homebrew/opt/qt/lib) on the main
# executable. Replace it with @executable_path/../Frameworks so dylibs that still
# use @rpath references (e.g. libsharpyuv via libwebp) resolve from inside the
# bundle instead of the build host. Then ad-hoc re-sign — install_name_tool
# invalidates Homebrew's existing signatures.
EXE="${APP_BUILD}/Contents/MacOS/AdaptixClient"
echo "[*] Fixing rpaths for portability"
if ! otool -l "$EXE" | awk '/LC_RPATH/{f=1} f && /path /{print; f=0}' \
       | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$EXE" 2>/dev/null || true
fi
otool -l "$EXE" | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}' \
    | grep -v '^@executable_path' \
    | while read -r rp; do
        [[ -n "$rp" ]] && install_name_tool -delete_rpath "$rp" "$EXE" 2>/dev/null || true
    done

echo "[*] Ad-hoc signing bundle"
codesign --force --deep --sign - "$APP_BUILD" >/dev/null

# ---- stage to dist -----------------------------------------------------------

echo "[*] Staging to $DIST_DIR"
rm -rf "${DIST_DIR}/AdaptixClient.app"
mv "$APP_BUILD" "${DIST_DIR}/AdaptixClient.app"
if (( DO_DMG )); then
    rm -f "${DIST_DIR}/AdaptixClient.dmg"
    mv "${BUILD_DIR}/AdaptixClient.dmg" "${DIST_DIR}/AdaptixClient.dmg" 2>/dev/null || true
fi

SIZE="$(du -sh "${DIST_DIR}/AdaptixClient.app" | awk '{print $1}')"
echo
echo "[+] Done. Bundle: ${DIST_DIR}/AdaptixClient.app  (${SIZE})"
(( DO_DMG )) && [[ -f "${DIST_DIR}/AdaptixClient.dmg" ]] && \
    echo "[+] DMG:    ${DIST_DIR}/AdaptixClient.dmg"
echo "[i] Run with: open ${DIST_DIR}/AdaptixClient.app"
echo "[i] Gatekeeper may block first launch (unsigned). Right-click → Open to allow."
