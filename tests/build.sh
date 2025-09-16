#!/bin/bash
set -exuo pipefail

# This script basically builds bootc from source using the provided base image,
# then runs the target tests.

# If provided should be of the form fedora-42 or centos-10
target=${1:-}

bcvk=$(which bcvk 2>/dev/null || true)
if test -z "${bcvk}" && test "$(id -u)" != 0; then
    echo "This script currently requires full root"; exit 1
fi

build_args=()
if test -n "${target:-}"; then
    shift
    # Get OS info from TEST_OS env
    OS_ID=$(echo "$target" | cut -d '-' -f 1)
    OS_VERSION_ID=$(echo "$target" | cut -d '-' -f 2)

    # Base image
    case "$OS_ID" in
        "centos")
            BASE="quay.io/centos-bootc/centos-bootc:stream${OS_VERSION_ID}"
        ;;
        "fedora")
            BASE="quay.io/fedora/fedora-bootc:${OS_VERSION_ID}"
        ;;
        *) echo "Unknown OS: ${OS_ID}" 1>&2; exit 1
        ;;
    esac
    build_args+=("--build-arg=base=$BASE")
fi

just build ${build_args[@]}
just build-integration-test-image

# Host builds will have this already, but we use it as a general dumping space
# for output artifacts
mkdir -p target

DISK=target/bootc-integration-test.raw
SIZE=10G
rm -vf "${DISK}"
if test -n "${bcvk}"; then
    bcvk to-disk --disk-size "${SIZE}" localhost/bootc-integration "${DISK}"
else
    truncate -s "${SIZE}" "${DISK}"
    podman run \
  --rm \
  --privileged \
  --pid=host \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers:/var/lib/containers \
  -v /dev:/dev \
  -v $(pwd)/target:/target \
  localhost/bootc-integration \
  bootc install to-disk \
  --filesystem "xfs" \
  --karg=console=ttyS0,115200n8 \
  --generic-image \
  --via-loopback \
  /target/$(basename ${DISK})
fi
# testcloud barfs on .raw sadly; FIXME drop this once it's been changed.
# Alternatively we could teach bcvk how to write qcow2 easily enough.
qemu-img convert -f raw -O qcow2 ${DISK} target/bootc-integration-test.qcow2
rm -f "${DISK}"

