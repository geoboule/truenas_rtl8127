#!/bin/bash
# Script to compile r8127 driver for TrueNAS SCALE using Docker
#
# Usage:
#   1. Copy this script to your TrueNAS host.
#   2. Run: chmod +x truenas_build_r8127_driver.sh && sudo ./truenas_build_r8127_driver.sh
#
# Prerequisites:
#   - TrueNAS SCALE 24.10+ (Electric Eel and newer) uses Docker for Apps.
#   - The `docker` CLI may be present, but `dockerd` typically does not start until
#     you configure Apps once in the web UI (select an Apps storage pool).
#
# Persistence:
#   The driver will be lost on reboot or system update. To make it persistent:
#   1. Copy the compiled .ko to a persistent pool:
#      cp /tmp/r8127_build/rtl8127/r8127.ko /mnt/YOUR_POOL/scripts/
#   2. Go to System Settings -> Advanced -> Init/Shutdown Scripts.
#   3. Add a 'Post Init' script with command: insmod /mnt/YOUR_POOL/scripts/r8127.ko
#
#   Note: If the built-in r8169 driver interferes, you may need to add another
#   Post Init script to unbind it or blacklist it, though usually insmod is sufficient.
#
# Notes:
#   - This script must be re-run after every TrueNAS SCALE version update to
#     recompile the driver against the new kernel headers.
#   - This script was developed with assistance from AI tools.
#   - Review the script and decide whether you trust it, rather than running it blindly.
#   - No warranty is provided; use at your own risk.
#   - I have tested on my TrueNAS SCALE 25.10.1 box with a Realtek RTL8127 NIC where it works as intended.

set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/tmp/r8127_build}"
IMAGE_NAME="${IMAGE_NAME:-r8127-builder}"
REPO_URL="${REPO_URL:-https://github.com/openwrt/rtl8127.git}"
DRIVER_REF="${DRIVER_REF:-}"
REBUILD_IMAGE="${REBUILD_IMAGE:-0}"

# Cleanup is intentionally disabled by default so you can copy the built .ko.
# Set CLEANUP=1 to delete the build directory on exit.
# Set CLEANUP_IMAGE=1 to also delete the builder image on exit.
CLEANUP="${CLEANUP:-0}"
CLEANUP_IMAGE="${CLEANUP_IMAGE:-0}"

HEADERS_DIR=""
SRC_DIR_NAME="rtl8127"

log() {
    printf '%s\n' "$*"
}

die() {
    log "Error: $*"
    exit 1
}

cleanup() {
    local exit_code=$?

    if [ "$CLEANUP" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
        log "--------------------------------------------------"
        log "Cleaning up build directory: $BUILD_DIR"
        rm -rf "$BUILD_DIR"
    fi

    if [ "$CLEANUP_IMAGE" -eq 1 ] && docker image inspect "$IMAGE_NAME" &> /dev/null; then
        log "--------------------------------------------------"
        log "Cleaning up Docker image: $IMAGE_NAME"
        docker rmi "$IMAGE_NAME" > /dev/null 2>&1 || true
    fi

    if [ "$exit_code" -eq 0 ] && [ "$CLEANUP" -ne 1 ]; then
        log "--------------------------------------------------"
        log "Build artifacts kept at: $BUILD_DIR"
        log "(Set CLEANUP=1 to delete build artifacts automatically.)"
    fi
}
trap cleanup EXIT

check_requirements() {
    log "Checking requirements..."

    # 1. Check for root/sudo privileges
    [[ $EUID -ne 0 ]] && die "This script must be run with sudo or as root."

    # 2. Check for required tools
    for cmd in docker git; do
        command -v "$cmd" &> /dev/null || die "'$cmd' is not installed or not in PATH. Is this a TrueNAS SCALE host?"
    done

    # 2b. Verify Docker daemon is reachable
    if ! docker info > /dev/null 2>&1; then
        die $'Docker daemon is not reachable.\nOn TrueNAS SCALE, configure Apps in the UI (choose an Apps pool) so Docker starts.'
    fi

    # 3. Check for kernel headers
    local kernel_version
    kernel_version=$(uname -r)
    local headers_path="/usr/src/linux-headers-$kernel_version"
    
    # Fallback to the production headers if the specific version link is missing
    [ ! -d "$headers_path" ] && headers_path="/usr/src/linux-headers-truenas-production-amd64"

    if [ ! -d "$headers_path" ]; then
        die "Kernel headers not found at $headers_path. Please ensure 'linux-headers-truenas-production-amd64' is installed."
    fi

    # Resolve symlinks for Docker mount
    HEADERS_DIR=$(readlink -f "$headers_path")
    [ -f "$HEADERS_DIR/Makefile" ] || die "Kernel headers directory does not look valid (missing Makefile): $HEADERS_DIR"
    log "Found kernel headers at: $HEADERS_DIR"
}

prepare_build_env() {
    log "Setting up build directory at $BUILD_DIR..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    if [ ! -d "$SRC_DIR_NAME" ]; then
        log "Cloning r8127 driver source..."
        if [ -n "$DRIVER_REF" ]; then
            git clone --depth 1 --branch "$DRIVER_REF" "$REPO_URL" "$SRC_DIR_NAME"
        else
            git clone --depth 1 "$REPO_URL" "$SRC_DIR_NAME"
        fi
    else
        [ -d "$SRC_DIR_NAME/.git" ] || die "Existing '$BUILD_DIR/$SRC_DIR_NAME' is not a git repo; remove it or pick a different BUILD_DIR."
        log "Driver source already exists at $BUILD_DIR/$SRC_DIR_NAME (skipping clone)."
    fi

    log "Creating build environment Dockerfile..."
    cat <<EOF > Dockerfile
FROM debian:bookworm
RUN apt-get update && apt-get install -y build-essential bc kmod libelf-dev flex bison && rm -rf /var/lib/apt/lists/*
WORKDIR /build
EOF

    if docker image inspect "$IMAGE_NAME" &> /dev/null && [ "$REBUILD_IMAGE" -ne 1 ]; then
        log "Docker image '$IMAGE_NAME' already exists (set REBUILD_IMAGE=1 to rebuild)."
    else
        log "Building Docker build image ($IMAGE_NAME)..."
        docker build -t "$IMAGE_NAME" .
    fi
}

compile_driver() {
    log "Compiling driver using headers from: $HEADERS_DIR"

    # We mount the host's kernel headers and the source code into the container
    docker run --rm \
        -v "$BUILD_DIR/$SRC_DIR_NAME:/build/$SRC_DIR_NAME:rw" \
        -v "$HEADERS_DIR:/kernel-headers:ro" \
        "$IMAGE_NAME" \
        bash -lc "$(cat <<EOF
set -euo pipefail

if [ ! -f /kernel-headers/include/generated/autoconf.h ]; then
    make -C /kernel-headers modules_prepare
fi

make -C /kernel-headers \
    M=/build/$SRC_DIR_NAME \
    KERNELDIR=/kernel-headers \
    modules
EOF
)"
}

install_and_verify() {
    local module_path="$BUILD_DIR/$SRC_DIR_NAME/r8127.ko"

    if [ ! -f "$module_path" ]; then
        die "Compilation failed. r8127.ko was not generated."
    fi

    log "--------------------------------------------------"
    log "SUCCESS: Driver compiled at $module_path"
    log "--------------------------------------------------"

    if command -v modinfo &> /dev/null; then
        log "Module info (vermagic etc.):"
        modinfo "$module_path" | grep -E '^(filename|description|version|vermagic):' || true
    fi

    local links_before
    links_before="$(
        ip -o link show |
            awk -F': ' '{print $2}' |
            sort || true
    )"

    # Load the module (temporary)
    if [ -d /sys/module/r8127 ] || lsmod | grep -qE '^r8127[[:space:]]'; then
        log "Module r8127 is already loaded. Attempting to unload..."
        rmmod r8127 || die $'Could not unload r8127. Is the interface in use?\nTry bringing the interface down before running this script.'
    fi

    log "Loading new module..."
    local insmod_err=""
    if ! insmod_err=$(insmod "$module_path" 2>&1); then
        if [ -d /sys/module/r8127 ] && printf '%s' "$insmod_err" | grep -qi "file exists"; then
            log "insmod reported 'File exists' (module already loaded). Continuing."
        else
            die "insmod failed: $insmod_err"
        fi
    fi

    log "Verifying module + interface binding..."

    log "Recent kernel messages containing 'r8127':"
    dmesg | tail -n 200 | grep -i "r8127" || true

    local links_after
    links_after="$(
        ip -o link show |
            awk -F': ' '{print $2}' |
            sort || true
    )"

    local new_ifaces
    new_ifaces="$(
        comm -13 \
            <(printf '%s\n' "$links_before") \
            <(printf '%s\n' "$links_after") || true
    )"
    if [ -n "$new_ifaces" ]; then
        log "New interfaces detected after loading module:"
        printf '%s\n' "$new_ifaces"
    fi

    if [ -d /sys/class/net ]; then
        local ifaces_using_driver=()
        local iface
        for iface in /sys/class/net/*; do
            local iface_name
            iface_name="$(basename "$iface")"
            if [ -e "$iface/device/driver/module" ]; then
                local module_name
                module_name="$(basename "$(readlink -f "$iface/device/driver/module")")"
                if [ "$module_name" = "r8127" ]; then
                    ifaces_using_driver+=("$iface_name")
                fi
            fi
        done
        if [ "${#ifaces_using_driver[@]}" -gt 0 ]; then
            log "Interfaces using r8127: ${ifaces_using_driver[*]}"
        else
            log "No interfaces currently report driver module r8127 via sysfs."
        fi
    fi

    log "Active interfaces:"
    ip -br link show | grep "UP" || log "(None UP)"

    log "--------------------------------------------------"
    log "NOTE: Don't forget to copy $module_path to your persistent storage, and to automate loading e.g. with a Post Init script in TrueNAS UI."
    log "--------------------------------------------------"
}

check_requirements
prepare_build_env
compile_driver
install_and_verify
