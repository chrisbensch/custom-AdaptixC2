#!/usr/bin/env bash
# Linux AppImage build of the AdaptixC2 Qt6 client, run inside the Docker
# build-client (amd64) or build-client-kali (arm64) stage.
# Output: ./AdaptixClient-dist/AdaptixClient-{x86_64,aarch64}.AppImage
#
# Usage:
#   ./build-client-linux.sh                  # build for host arch
#   ./build-client-linux.sh --arch amd64     # force x86_64 AppImage
#   ./build-client-linux.sh --arch arm64     # force aarch64 AppImage
#   ./build-client-linux.sh --clean          # wipe dist dir first
#
# Requires: Docker with Compose v2.
#
# Two build paths:
#   amd64 → build-client stage (ubuntu:22.04 + aqtinstall Qt 6.9.2 +
#           linuxdeployqt + appimagetool, all x86_64-only)
#   arm64 → build-client-kali stage (kalilinux/kali-rolling + distro Qt 6.10.2 +
#           linuxdeploy + linuxdeploy-plugin-qt, both arches supported)
#
# The arm64 path exists because aqtinstall publishes no Linux aarch64 Qt
# binaries for any version through 6.11.x; Kali's distro Qt6 fills the gap.
# Applies patches/adaptixclient-kali-arm64-stage.patch to AdaptixC2/Dockerfile
# for the duration of the build (auto-reverts on exit).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/AdaptixClient-dist"
COMPOSE_PROFILE="build-client"
COMPOSE_SVC="client-linux"
PATCH="${SCRIPT_DIR}/patches/adaptixclient-kali-arm64-stage.patch"
ADAPTIX_REPO="${SCRIPT_DIR}/AdaptixC2"

DO_CLEAN=0
ARCH=host
while (( $# )); do
    case "$1" in
        --clean) DO_CLEAN=1; shift ;;
        --arch)
            [[ $# -ge 2 ]] || { echo "[!] --arch requires a value (host|amd64|arm64)" >&2; exit 2; }
            ARCH="$2"; shift 2 ;;
        --arch=*) ARCH="${1#*=}"; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *)
            echo "[!] Unknown flag: $1" >&2
            echo "    Use --arch <host|amd64|arm64>, --clean, or -h for help." >&2
            exit 2 ;;
    esac
done

# ---- resolve target arch -----------------------------------------------------

if [[ "$ARCH" == "host" ]]; then
    case "$(uname -m)" in
        x86_64|amd64)  ARCH=amd64 ;;
        arm64|aarch64) ARCH=arm64 ;;
        *) echo "[!] Unsupported host arch: $(uname -m). Pass --arch amd64|arm64." >&2; exit 1 ;;
    esac
fi

case "$ARCH" in
    amd64)
        DOCKER_PLATFORM=linux/amd64
        IMG_ARCH=x86_64
        BUILD_TARGET=build-client
        ;;
    arm64)
        DOCKER_PLATFORM=linux/arm64
        IMG_ARCH=aarch64
        BUILD_TARGET=build-client-kali
        ;;
    *)
        echo "[!] --arch must be host, amd64, or arm64 (got: $ARCH)" >&2
        exit 2 ;;
esac

APPIMAGE="${DIST_DIR}/AdaptixClient-${IMG_ARCH}.AppImage"

# ---- preflight ---------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    echo "[!] docker not found. Install Docker Desktop or the Docker engine." >&2
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "[!] 'docker compose' (v2) not available. Update Docker." >&2
    exit 1
fi

if [[ ! -f "${ADAPTIX_REPO}/Dockerfile" ]]; then
    echo "[!] AdaptixC2 submodule not initialized at ${ADAPTIX_REPO}." >&2
    echo "    Run: git submodule update --init --recursive" >&2
    exit 1
fi

if [[ ! -f "$PATCH" ]]; then
    echo "[!] Patch missing: $PATCH" >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64)  HOST_ARCH=amd64 ;;
    arm64|aarch64) HOST_ARCH=arm64 ;;
    *) HOST_ARCH=unknown ;;
esac
if [[ "$HOST_ARCH" != "$ARCH" ]]; then
    echo "[i] Host is $HOST_ARCH, target is $ARCH; build runs under QEMU emulation."
    echo "    First build can take 10+ minutes; subsequent builds use the layer cache."
fi

# ---- apply kali arm64 stage patch (auto-revert on exit) ----------------------

if git -C "$ADAPTIX_REPO" apply --check "$PATCH" 2>/dev/null; then
    echo "[*] Applying $PATCH"
    git -C "$ADAPTIX_REPO" apply "$PATCH"
    trap 'git -C "$ADAPTIX_REPO" apply -R "$PATCH" 2>/dev/null || true' EXIT
elif git -C "$ADAPTIX_REPO" apply --check -R "$PATCH" 2>/dev/null; then
    echo "[+] Patch already applied (dirty submodule); leaving as-is"
else
    echo "[!] Patch $PATCH no longer applies — upstream Dockerfile has drifted." >&2
    echo "    Resolve manually, regenerate the patch, then re-run." >&2
    exit 1
fi

# ---- clean (optional) --------------------------------------------------------

if (( DO_CLEAN )); then
    echo "[*] Wiping $DIST_DIR"
    rm -rf "$DIST_DIR"
fi
mkdir -p "$DIST_DIR"

# ---- build -------------------------------------------------------------------
# Compose service reads ADAPTIX_CLIENT_* env vars to pick platform + target.

export ADAPTIX_CLIENT_ARCH="$ARCH"
export ADAPTIX_CLIENT_PLATFORM="$DOCKER_PLATFORM"
export ADAPTIX_CLIENT_TARGET="$BUILD_TARGET"
export ADAPTIX_CLIENT_IMG_ARCH="$IMG_ARCH"

echo "[*] Building Linux client (arch=$ARCH, platform=$DOCKER_PLATFORM, target=$BUILD_TARGET)"
docker compose --profile "$COMPOSE_PROFILE" up --build --abort-on-container-exit "$COMPOSE_SVC"

# ---- verify + tidy -----------------------------------------------------------

if [[ ! -f "$APPIMAGE" ]]; then
    echo "[!] Build did not produce $APPIMAGE." >&2
    echo "    Inspect compose output above for the failing step." >&2
    exit 1
fi
chmod +x "$APPIMAGE"

# AppDir is build-time staging; prune it so dist holds only AppImage(s).
rm -rf "${DIST_DIR}/AdaptixClient.AppDir"

SIZE="$(du -sh "$APPIMAGE" | awk '{print $1}')"
echo
echo "[+] Done. AppImage: $APPIMAGE  ($SIZE)"
echo "[i] Run with: $APPIMAGE"
echo "[i] If FUSE is unavailable: $APPIMAGE --appimage-extract-and-run"
