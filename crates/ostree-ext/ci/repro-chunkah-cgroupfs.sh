#!/bin/bash
# Variant of repro-chunkah-only.sh: drops `systemd-run -dP --wait` (as in
# repro-chunkah-no-systemd-run.sh) AND additionally passes
# --cgroup-manager=cgroupfs to the podman invocations. This is the
# fallback tested only if the plain systemd-run removal in
# repro-chunkah-no-systemd-run.sh turns out to hit a real cgroup
# delegation error on the nested `podman run` (the chunkah build creates
# its own container). --cgroup-manager=cgroupfs tells podman to manage
# cgroups directly via cgroupfs instead of asking systemd for a transient
# scope, which sidesteps any systemd/dbus interaction entirely -- see the
# bootc PR #2394 "chunkah hang" investigation notes / AGENTS.md.
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
podman --cgroup-manager=cgroupfs info
date -Iseconds; echo "=== skopeo copy to OCI dir ==="
skopeo copy containers-storage:${image} oci:/var/tmp/fcos-oci:latest
date -Iseconds; echo "=== chunkah build ==="
podman --cgroup-manager=cgroupfs --log-level=debug run --rm --network=none \
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
