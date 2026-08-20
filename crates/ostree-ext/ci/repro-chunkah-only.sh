#!/bin/bash
# Minimal repro for the "chunkah hang" seen in priv-integration.sh
# (bootc PR #2394). Extracted from the chunkah section of that script
# (see `git log` there for the full context/history).
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
systemd-run -dP --wait podman info
date -Iseconds; echo "=== skopeo copy to OCI dir ==="
systemd-run -dP --wait skopeo copy containers-storage:${image} oci:/var/tmp/fcos-oci:latest
date -Iseconds; echo "=== chunkah build ==="
systemd-run -dP --wait podman --log-level=debug run --rm --network=none \
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
