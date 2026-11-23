#!/bin/bash
# Script to compile r8127 driver for TrueNAS SCALE using Docker
#
# Usage:
#   1. Copy this script to your TrueNAS host.
#   2. Build only (safe to run over the r8127 interface itself):
#        sudo bash truenas_build_r8127_driver.sh
#   3. Build, install for the running kernel and register the boot loader, so the
#      module is loaded from the next boot on (add LOAD_MODULE=1 to load it now):
#        sudo INSTALL_DIR=/mnt/YOUR_POOL/scripts POSTINIT=1 bash truenas_build_r8127_driver.sh
#
# Options (environment variables):
#   INSTALL_DIR=<dir>   Copy the module to <dir>/r8127-<kernel>.ko and write the boot
#                       loader <dir>/load_r8127.sh (see Persistence).
#   POSTINIT=1          With INSTALL_DIR, create or update a Post Init task that runs
#                       the loader. Only the task with the comment "r8127 loader
#                       (managed by truenas_build_r8127_driver.sh)" is managed;
#                       other tasks mentioning r8127 are reported, not changed.
#   LOAD_MODULE=1       Load the new module now (with INSTALL_DIR, by running the
#                       installed loader, as at boot). Off by default: a loaded r8127
#                       must be unloaded first, which drops the network on its
#                       interfaces.
#   FORCE_RELOAD=1      With LOAD_MODULE=1, unload r8127 even when one of its
#                       interfaces carries the default route.
#   DRIVER_REF=<ref>    Tag, commit or branch of the driver source to build; default
#                       11.017.02, the newest release tag. A clone in BUILD_DIR that
#                       is already at the tag or commit is reused without network
#                       access. DRIVER_REF= (empty) takes the default branch, or
#                       reuses an existing clone as is.
#   Also: REPO_URL, BUILD_DIR, BASE_IMAGE, IMAGE_NAME, REBUILD_IMAGE=1.
#
# Prerequisites:
#   - TrueNAS SCALE 24.10+ (Electric Eel and newer) uses Docker for Apps.
#   - The `docker` CLI may be present, but `dockerd` typically does not start until
#     you configure Apps once in the web UI (select an Apps storage pool).
#   - The Apps service will not start without a default route. If the r8127 NIC is
#     the only configured interface, it is down after an upgrade until this script
#     has run, so first give another interface (e.g. the onboard NIC on r8169) an
#     address and gateway, for example by enabling DHCP on it.
#   - Modules must be built with the compiler that built the kernel, so the builder
#     image's Debian release follows the compiler named in /proc/version: bookworm
#     for GCC 12 (TrueNAS 25.10), trixie for GCC 14 (reported for TrueNAS 26).
#     BASE_IMAGE overrides it.
#   - The first run needs internet access (apt-get in the image build, git clone).
#     The builder image does not depend on the kernel version and the source is kept
#     in BUILD_DIR, so later runs, including after an upgrade, work offline, except
#     the first run after an upgrade that moves to a new Debian release, which
#     builds that release's image once.
#
# Persistence:
#   A module only loads on the kernel it was built for, so install one per kernel
#   with INSTALL_DIR (older ones are kept for booting back into an older boot
#   environment; a replaced build for the same kernel is kept as
#   r8127-<kernel>.ko.<driver version>.bak). INSTALL_DIR also gets load_r8127.sh,
#   which loads the module for the running kernel at boot. Run with POSTINIT=1 to
#   register it, or add it as a 'Post Init' command under System Settings ->
#   Advanced -> Init/Shutdown Scripts:
#     sh /mnt/YOUR_POOL/scripts/load_r8127.sh
#   or from a shell (to change an existing task, use
#   `initshutdownscript.update <id> '{...}'`, ids from `initshutdownscript.query`):
#     midclt call initshutdownscript.create '{"type": "COMMAND", "when": "POSTINIT", "enabled": true, "timeout": 30, "comment": "r8127 loader (managed by truenas_build_r8127_driver.sh)", "command": "sh /mnt/YOUR_POOL/scripts/load_r8127.sh"}'
#   (with that comment, a later POSTINIT=1 run manages this task instead of adding one).
#   Post Init runs after the network is configured, when the r8127 interface did
#   not exist yet: without a re-sync the default route is missing and Apps fail
#   with "Unable to determine default interface". The loader waits for the
#   interface, runs `interface.sync`, and starts Apps unless they are already
#   running or starting. It logs to the journal (`journalctl -t r8127`), finishes
#   within about 20 seconds, and is safe to run again on a running system.
#
# Notes:
#   - This script must be re-run after every TrueNAS SCALE version update to
#     recompile the driver against the new kernel headers.
#   - This script was developed with assistance from AI tools.
#   - Review the script and decide whether you trust it, rather than running it blindly.
#   - No warranty is provided; use at your own risk.
#   - I have tested on my TrueNAS SCALE 25.10.4 box with a Realtek RTL8127 NIC where it works as intended.

set -euo pipefail

KERNEL_VERSION=$(uname -r)
# Absolute: the script changes into it, and docker -v reads a relative name as a volume.
BUILD_DIR=$(realpath -m "${BUILD_DIR:-$PWD/r8127_build}")
# The Debian release whose default compiler built the kernel, from the compiler string
# in /proc/version, e.g. "gcc (Debian 12.2.0-14+deb12u1) 12.2.0". Empty if unknown.
debian_release_for_kernel() {
    case "$1" in
        *'+deb12u'* | *'(Debian 12.'*) echo bookworm ;;
        *'+deb13u'* | *'(Debian 14.'*) echo trixie ;;
    esac
}
KERNEL_GCC=$(grep -o 'gcc ([^)]*) [0-9.]*' /proc/version || true)
if [ -n "${BASE_IMAGE:-}" ]; then
    BASE_IMAGE_REASON="set by BASE_IMAGE"
elif release=$(debian_release_for_kernel "$KERNEL_GCC") && [ -n "$release" ]; then
    BASE_IMAGE="debian:$release"
    BASE_IMAGE_REASON="matches the kernel's compiler"
else
    BASE_IMAGE="debian:bookworm"
    BASE_IMAGE_REASON="kernel compiler '${KERNEL_GCC:-unknown}' not recognised; set BASE_IMAGE to the matching Debian release"
fi
# The image holds only the toolchain; kernel headers are mounted at build time, so
# one image serves every kernel and a rebuild after an upgrade needs no network.
IMAGE_NAME="${IMAGE_NAME:-r8127-builder:${BASE_IMAGE##*:}}"
REPO_URL="${REPO_URL:-https://github.com/openwrt/rtl8127.git}"
# Release tags of the repo above; an empty DRIVER_REF (set, not unset) opts out.
DRIVER_REF="${DRIVER_REF-11.017.02}"
REBUILD_IMAGE="${REBUILD_IMAGE:-0}"
INSTALL_DIR="${INSTALL_DIR:-}"
LOAD_MODULE="${LOAD_MODULE:-0}"
POSTINIT="${POSTINIT:-0}"
# POSTINIT=1 manages only the Post Init task whose comment is exactly this.
POSTINIT_COMMENT="r8127 loader (managed by truenas_build_r8127_driver.sh)"
FORCE_RELOAD="${FORCE_RELOAD:-0}"

HEADERS_DIR=""
SRC_DIR_NAME="rtl8127"
MODULE_NAME="r8127-$KERNEL_VERSION.ko"
MODULE_PATH="$BUILD_DIR/$MODULE_NAME"

log() {
    printf '%s\n' "$*"
}

die() {
    log "Error: $*" >&2
    exit 1
}

check_requirements() {
    log "Checking requirements..."

    [[ $EUID -ne 0 ]] && die "This script must be run with sudo or as root."

    for cmd in docker git modinfo; do
        command -v "$cmd" &> /dev/null || die "'$cmd' is not installed or not in PATH. Is this a TrueNAS SCALE host?"
    done
    if [ -n "$INSTALL_DIR" ]; then
        # Post Init runs from an unknown directory, so record an absolute path.
        INSTALL_DIR=$(realpath -m "$INSTALL_DIR")
    fi
    if [ "$POSTINIT" -eq 1 ]; then
        [ -n "$INSTALL_DIR" ] || die "POSTINIT=1 needs INSTALL_DIR (the loader is written there)."
        [[ $INSTALL_DIR =~ ^[A-Za-z0-9_./+-]+$ ]] ||
            die "POSTINIT=1 supports INSTALL_DIR paths of letters, digits and _./+- only; add the Post Init command by hand (see Persistence)."
        for cmd in midclt python3; do
            command -v "$cmd" &> /dev/null || die "POSTINIT=1 needs '$cmd'. Is this a TrueNAS SCALE host?"
        done
    fi

    if ! docker info > /dev/null 2>&1; then
        die $'Docker daemon is not reachable.\nOn TrueNAS SCALE, configure Apps in the UI (choose an Apps pool) so Docker starts.\nApps also need a default route: see Prerequisites at the top of this script.'
    fi

    # Fall back to the production headers if the versioned directory is missing.
    # These may belong to a different kernel; the vermagic check after the build
    # catches that.
    local headers_path="/usr/src/linux-headers-$KERNEL_VERSION"
    [ ! -d "$headers_path" ] && headers_path="/usr/src/linux-headers-truenas-production-amd64"
    [ -d "$headers_path" ] || die "Kernel headers not found at $headers_path. Please ensure 'linux-headers-truenas-production-amd64' is installed."

    # Resolve symlinks for Docker mount
    HEADERS_DIR=$(readlink -f "$headers_path")
    [ -f "$HEADERS_DIR/Makefile" ] || die "Kernel headers directory does not look valid (missing Makefile): $HEADERS_DIR"
    log "Found kernel headers at: $HEADERS_DIR"
}

fetch_source() {
    if [ ! -d "$SRC_DIR_NAME" ]; then
        log "Fetching r8127 driver source${DRIVER_REF:+ at $DRIVER_REF}..."
        if [ -z "$DRIVER_REF" ]; then
            git clone --depth 1 "$REPO_URL" "$SRC_DIR_NAME"
            return
        fi
        git init -q "$SRC_DIR_NAME"
        git -C "$SRC_DIR_NAME" remote add origin "$REPO_URL"
    else
        [ -d "$SRC_DIR_NAME/.git" ] || die "Existing '$BUILD_DIR/$SRC_DIR_NAME' is not a git repo; remove it or pick a different BUILD_DIR."
        if [ -z "$DRIVER_REF" ]; then
            log "Reusing driver source at $BUILD_DIR/$SRC_DIR_NAME (DRIVER_REF is empty)."
            return
        fi
        # Already at the requested tag or commit: reuse it, no network needed.
        local want
        want=$(git -C "$SRC_DIR_NAME" rev-parse -q --verify "$DRIVER_REF^{commit}" || true)
        if [ -n "$want" ] && [ "$want" = "$(git -C "$SRC_DIR_NAME" rev-parse HEAD)" ]; then
            log "Reusing driver source at $BUILD_DIR/$SRC_DIR_NAME, already at $DRIVER_REF."
            return
        fi
        log "Updating driver source to $DRIVER_REF..."
    fi
    # `git clone --branch` cannot take a commit hash; fetching the ref can, as well
    # as branches and tags.
    git -C "$SRC_DIR_NAME" fetch -q --depth 1 origin "$DRIVER_REF"
    git -C "$SRC_DIR_NAME" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
    # Keep a fetched tag locally, so a rerun can recognise it without the network.
    if git -C "$SRC_DIR_NAME" ls-remote -q --exit-code --tags origin "refs/tags/$DRIVER_REF" > /dev/null; then
        git -C "$SRC_DIR_NAME" tag -f "$DRIVER_REF" FETCH_HEAD > /dev/null
    fi
}

prepare_build_env() {
    log "Setting up build directory at $BUILD_DIR..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    fetch_source
    log "Driver source commit: $(git -C "$SRC_DIR_NAME" log -1 --format='%H (%cs) %s')"

    log "Builder base image: $BASE_IMAGE ($BASE_IMAGE_REASON)."
    cat << EOF > Dockerfile
FROM $BASE_IMAGE
RUN apt-get update && apt-get install -y build-essential bc kmod libelf-dev flex bison && rm -rf /var/lib/apt/lists/*
WORKDIR /build
EOF

    if docker image inspect "$IMAGE_NAME" &> /dev/null && [ "$REBUILD_IMAGE" -ne 1 ]; then
        log "Docker image '$IMAGE_NAME' already exists (set REBUILD_IMAGE=1 to rebuild)."
    else
        log "Building Docker build image ($IMAGE_NAME)..."
        docker build -t "$IMAGE_NAME" .
    fi

    # Modules should be built with the compiler the kernel was built with.
    local image_gcc
    image_gcc=$(docker run --rm "$IMAGE_NAME" gcc --version | head -n 1)
    log "Kernel built with: ${KERNEL_GCC:-unknown}; builder image has: $image_gcc"
    if [ -n "$KERNEL_GCC" ] && [ "$KERNEL_GCC" != "$image_gcc" ]; then
        log "Warning: compiler differs from the kernel's; set BASE_IMAGE to the matching Debian release if the build fails or the module misbehaves."
    fi
}

compile_driver() {
    log "Compiling driver using headers from: $HEADERS_DIR"

    # `clean` first: a source tree reused from a previous kernel must not leave its
    # objects or r8127.ko behind.
    docker run --rm \
        -v "$BUILD_DIR/$SRC_DIR_NAME:/build/$SRC_DIR_NAME:rw" \
        -v "$HEADERS_DIR:/kernel-headers:ro" \
        "$IMAGE_NAME" \
        bash -lc "$(
            cat << EOF
set -euo pipefail

if [ ! -f /kernel-headers/include/generated/autoconf.h ]; then
    make -C /kernel-headers modules_prepare
fi

make -C /kernel-headers M=/build/$SRC_DIR_NAME KERNELDIR=/kernel-headers clean
make -C /kernel-headers M=/build/$SRC_DIR_NAME KERNELDIR=/kernel-headers modules
EOF
        )"
}

verify_module() {
    local built="$BUILD_DIR/$SRC_DIR_NAME/r8127.ko"
    [ -f "$built" ] || die "Compilation failed. r8127.ko was not generated."

    # vermagic starts with the kernel release the module was built for; insmod
    # rejects any other kernel ("disagrees about version of symbol module_layout").
    local vermagic
    vermagic=$(modinfo -F vermagic "$built")
    if [ "${vermagic%% *}" != "$KERNEL_VERSION" ]; then
        die "Module was built for kernel '${vermagic%% *}', but the running kernel is '$KERNEL_VERSION'. The headers at $HEADERS_DIR belong to another kernel."
    fi

    cp "$built" "$MODULE_PATH"
    log "--------------------------------------------------"
    log "SUCCESS: Driver compiled at $MODULE_PATH"
    modinfo "$MODULE_PATH" | grep -E '^(version|vermagic):' || true
    log "--------------------------------------------------"
}

install_module() {
    if [ -z "$INSTALL_DIR" ]; then
        log "Not installed: rerun with INSTALL_DIR=/mnt/YOUR_POOL/scripts to keep it across reboots (see Persistence)."
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    local target="$INSTALL_DIR/$MODULE_NAME"
    if [ -f "$target" ] && ! cmp -s "$MODULE_PATH" "$target"; then
        local backup
        backup="$target.$(modinfo -F version "$target" || echo unknown).bak"
        [ -e "$backup" ] && backup="${backup%.bak}.$(date +%Y%m%d-%H%M%S).bak"
        log "Keeping the previous build for this kernel as $backup"
        cp -p "$target" "$backup"
    fi
    cp "$MODULE_PATH" "$target"
    log "Installed $target"
    write_loader "$INSTALL_DIR/load_r8127.sh"
    log "Post Init command: sh $INSTALL_DIR/load_r8127.sh"
}

# POSTINIT=1: create or update the Post Init task marked with POSTINIT_COMMENT so it
# runs the loader; other tasks are only reported.
configure_postinit() {
    [ "$POSTINIT" -eq 1 ] || return 0

    local command="sh $INSTALL_DIR/load_r8127.sh"

    # Only tasks whose comment is exactly POSTINIT_COMMENT are managed. Prints, oldest
    # first, "managed <id> <enabled> <command matches>" for those, and "other <id>"
    # for any other enabled Post Init task that mentions r8127.
    local tasks
    tasks=$(midclt call initshutdownscript.query | python3 -c '
import json, sys
command, marker = sys.argv[1:]
for t in sorted(json.load(sys.stdin), key=lambda t: t["id"]):
    if t["comment"] == marker:
        print("managed", t["id"], int(t["enabled"]), int(t["command"] == command and t["when"] == "POSTINIT"))
    elif t["enabled"] and t["when"] == "POSTINIT" and "r8127" in (t["command"] or "") + (t["script"] or ""):
        print("other", t["id"])
' "$command" "$POSTINIT_COMMENT")

    local payload
    payload=$(python3 -c '
import json, sys
print(json.dumps({"type": "COMMAND", "when": "POSTINIT", "enabled": True, "timeout": 30,
                  "comment": sys.argv[2], "command": sys.argv[1]}))
' "$command" "$POSTINIT_COMMENT")

    local kind id enabled matches managed=0
    while read -r kind id enabled matches; do
        case "$kind" in
            managed)
                managed=$((managed + 1))
                if [ "$managed" -gt 1 ]; then
                    if [ "$enabled" -eq 1 ]; then
                        midclt call initshutdownscript.update "$id" '{"enabled": false}' > /dev/null
                        log "Disabled duplicate managed Post Init task $id."
                    fi
                elif [ "$enabled" -eq 1 ] && [ "$matches" -eq 1 ]; then
                    log "Post Init task $id already runs: $command"
                else
                    midclt call initshutdownscript.update "$id" "$payload" > /dev/null
                    log "Updated Post Init task $id to run: $command"
                fi
                ;;
            other)
                log "Warning: Post Init task $id also mentions r8127 and is not managed by this script; disable it if it loads the driver too."
                ;;
        esac
    done <<< "$tasks"

    if [ "$managed" -eq 0 ]; then
        id=$(midclt call initshutdownscript.create "$payload" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')
        log "Created Post Init task $id: $command"
    fi
}

# The boot loader run by Post Init. POSIX sh: Post Init runs commands with sh -c.
write_loader() {
    cat << 'EOF' > "$1"
#!/bin/sh
# Written by truenas_build_r8127_driver.sh; changes here are lost on its next run.
# Loads the r8127 module built for the running kernel from this directory, then
# re-applies the saved network configuration (Post Init runs after the network
# is configured, before the r8127 interface exists) and starts Apps if needed.
# Post Init command: sh /path/to/load_r8127.sh
set -u
dir=$(dirname "$(readlink -f "$0")")
module="$dir/r8127-$(uname -r).ko"
status=0

log() {
    printf '%s\n' "$*"
    logger -t r8127 -- "$*" 2> /dev/null || true
}

r8127_interface() {
    for link in /sys/class/net/*/device/driver/module; do
        [ "$(basename "$(readlink -f "$link")")" = r8127 ] || continue
        link=${link%/device/driver/module}
        echo "${link##*/}"
        return 0
    done
    return 1
}

if [ -d /sys/module/r8127 ]; then
    log "r8127 is already loaded."
elif [ ! -f "$module" ]; then
    log "No r8127 module for kernel $(uname -r): $module is missing. Rebuild it with truenas_build_r8127_driver.sh."
    exit 1
elif err=$(insmod "$module" 2>&1); then
    log "Loaded $module (driver $(modinfo -F version "$module"))."
else
    log "insmod $module failed: $err"
    exit 1
fi

i=0
until iface=$(r8127_interface); do
    i=$((i + 1))
    if [ "$i" -gt 15 ]; then
        log "No interface is bound to r8127 after 15 s; applying the network configuration anyway."
        break
    fi
    sleep 1
done
[ -n "${iface:-}" ] && log "Interface $iface is bound to r8127."
# Give the middleware's own hotplug handling of the new interface a moment.
sleep 2

if midclt call interface.sync > /dev/null; then
    log "Applied the saved network configuration. Default route: $(ip -4 route show default)"
else
    log "midclt call interface.sync failed."
    status=1
fi

# START on running Apps re-initializes them, so only start them when needed.
# service.control is a job: midclt returns its id and Apps start in the background.
apps=$(midclt call docker.status | sed -n 's/.*"status": *"\([A-Z_]*\)".*/\1/p')
case "$apps" in
    RUNNING | INITIALIZING) log "Apps are $apps; not starting them." ;;
    *)
        if job=$(midclt call service.control START docker); then
            log "Apps were ${apps:-in an unknown state}; starting them (job $job)."
        else
            log "Could not start Apps."
            status=1
        fi
        ;;
esac
exit "$status"
EOF
    chmod 755 "$1"
    log "Wrote $1"
}

# Interfaces whose device is bound to the r8127 driver, one per line.
r8127_interfaces() {
    local iface module
    for iface in /sys/class/net/*; do
        [ -e "$iface/device/driver/module" ] || continue
        module=$(basename "$(readlink -f "$iface/device/driver/module")")
        [ "$module" = "r8127" ] && basename "$iface"
    done
    return 0
}

unload_loaded_module() {
    [ -d /sys/module/r8127 ] || return 0

    local default_ifaces iface
    default_ifaces=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}')
    while read -r iface; do
        [ -n "$iface" ] || continue
        if grep -qxF "$iface" <<< "$default_ifaces" && [ "$FORCE_RELOAD" -ne 1 ]; then
            local next
            if [ -n "$INSTALL_DIR" ]; then
                next="It is installed; reboot to load it (the Post Init loader picks it up),"
            else
                next="Rerun with INSTALL_DIR (and POSTINIT=1) to load it at the next boot,"
            fi
            die "r8127 is loaded and its interface $iface carries the default route. Unloading it would cut the network, likely including this session. $next or rerun with FORCE_RELOAD=1."
        fi
    done <<< "$(r8127_interfaces)"

    log "Unloading the loaded r8127 module..."
    rmmod r8127 || die "Could not unload r8127. Bring its interfaces down and try again."
}

load_module() {
    if [ "$LOAD_MODULE" -ne 1 ]; then
        log "Not loaded: set LOAD_MODULE=1 to load it now."
        return 0
    fi

    unload_loaded_module
    if [ -n "$INSTALL_DIR" ]; then
        # The same path as at boot: load, wait for the interface, sync, start Apps.
        log "Running $INSTALL_DIR/load_r8127.sh..."
        sh "$INSTALL_DIR/load_r8127.sh" || die "The loader failed; see its messages above."
    else
        log "Loading $MODULE_PATH..."
        insmod "$MODULE_PATH" || die "insmod failed."
        if command -v midclt &> /dev/null; then
            log "Applying the saved network configuration (midclt call interface.sync)..."
            sleep 10
            midclt call interface.sync > /dev/null || log "Warning: interface.sync failed; check the network settings in the UI."
        fi
    fi

    log "Recent kernel messages containing 'r8127':"
    dmesg | tail -n 200 | grep -i "r8127" || true
    log "Interfaces using r8127: $(r8127_interfaces | tr '\n' ' ')"
    log "Default route: $(ip -4 route show default || true)"
}

check_requirements
prepare_build_env
compile_driver
verify_module
install_module
configure_postinit
load_module
log "Build artifacts kept at: $BUILD_DIR"
