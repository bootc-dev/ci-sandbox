#!/bin/bash
# Variant of repro-chunkah-only.sh with the `systemd-run -dP --wait` prefix
# simply removed from all three invocations. This tests whether
# systemd-run is actually needed here, per the bootc PR #2394 "chunkah
# hang" investigation (see AGENTS.md / repro-chunkah-only.sh for the full
# context, and the accompanying commit message for what we found in the
# upstream git history rationale).
#
# If nested `podman run` (the chunkah build, which itself creates a
# container) needs systemd-run to hand it a delegated cgroup scope, this
# script should fail with a podman/runc cgroup-related error on the third
# command. If it succeeds and produces a valid, non-empty
# /var/tmp/nonostree.ociarchive, that's strong evidence systemd-run was
# unnecessary for this specific set of commands.
#
# Deviations from the real script, and why:
#  - No `ostree admin init-fs` / sysroot setup: `--prune /sysroot/` passed to
#    chunkah refers to a path *inside the rootfs being converted* (i.e. under
#    the /chunkah mount), not a real ostree sysroot on the host. FCOS images
#    ship an empty /sysroot directory as an ostree convention, so nothing
#    needs to be initialized for this flag to make sense. See
#    https://github.com/coreos/chunkah#compatibility-with-bootable-bootc-images
#  - Everything upstream of the chunkah step (ostree deploys, derived image
#    tests, etc.) is dropped since it's not needed to reach the chunkah step.
set -xeuo pipefail
mkdir -p /var/tmp
image=quay.io/fedora/fedora-coreos:testing-devel
date -Iseconds; echo "=== Pulling FCOS image ==="
podman pull ${image}
chunkah_config="$(podman inspect ${image})"
date -Iseconds; echo "=== podman info ==="
podman info
date -Iseconds; echo "=== skopeo copy to OCI dir ==="
skopeo copy containers-storage:${image} oci:/var/tmp/fcos-oci:latest
date -Iseconds; echo "=== chunkah build ==="
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
