#!/bin/bash
# Tests whether the outer container's own cgroup delegation for nested
# `podman run` (the chunkah build) is decided once, at outer container
# creation time (based on whatever mounts were passed to `podman run
# --privileged ...`), or dynamically, per nested-podman-invocation, based
# on the *current* state of /run/systemd inside the running container.
#
# Three prior experiments (5a3779dc, this repo's cgroupfs-both-levels
# variant) all kept /run/systemd bind-mounted into the outer container for
# its entire lifetime and all failed identically with a "pids controller
# not available" cgroup delegation error at the nested chunkah `podman
# run`, regardless of --cgroup-manager flags at any level. If that failure
# is baked in at outer-container-creation time (because crun/podman
# decides how to mount/delegate /sys/fs/cgroup for a --privileged
# container based on whether /run/systemd is visible in the container's
# spec at creation), then removing the mount *after* the container has
# already started -- once the systemd-journal-dependent part of the real
# script has already run -- won't help. If it's decided dynamically (each
# nested podman invocation just checks sd_booted() itself), then
# unmounting /run/systemd mid-script, right before the systemd-run-free
# derived-image/chunkah section, should let cgroupfs mode work cleanly,
# exactly like the from-scratch no-host-systemd variant did.
#
# This is the outer container's own /run/systemd bind mount being
# unmounted from *inside* the running container (a --privileged container
# can do this to its own mount table) -- not touching the host's real
# /run/systemd at all.
set -xeuo pipefail
mkdir -p /var/tmp

echo "=== /run/systemd present before umount? ==="
test -d /run/systemd && echo yes || echo no

echo "=== Unmounting /run/systemd from this container's own mount namespace ==="
umount /run/systemd

echo "=== /run/systemd present after umount? ==="
test -d /run/systemd && echo yes || echo no

image=quay.io/fedora/fedora-coreos:testing-devel
date -Iseconds; echo "=== Pulling FCOS image ==="
podman pull ${image}
chunkah_config="$(podman inspect ${image})"
date -Iseconds; echo "=== podman info (post-umount) ==="
podman info
date -Iseconds; echo "=== skopeo copy to OCI dir ==="
skopeo copy containers-storage:${image} oci:/var/tmp/fcos-oci:latest
date -Iseconds; echo "=== chunkah build (no systemd-run, no --cgroup-manager flag) ==="
podman --log-level=debug run --rm --network=none \
    -v /var/tmp/fcos-oci:/chunkah:ro \
    -v /var/tmp:/output:z \
    -e CHUNKAH_CONFIG_STR="${chunkah_config}" \
    -e RUST_LOG=chunkah=debug \
    quay.io/coreos/chunkah build \
    --prune /sysroot/ \
    --label ostree.commit- \
    --label ostree.final-diffid- \
    -o /output/nonostree.ociarchive
date -Iseconds; echo "=== DONE ==="
ls -lh /var/tmp/nonostree.ociarchive
