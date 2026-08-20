#!/bin/bash
# Final validation of the actual proposed upstream patch (see
# repro-chunkah-no-host-systemd.yml / AGENTS.md for the full
# investigation), reusing the EXACT patched command text -- not a
# simplified stand-in like repro-chunkah-only.sh /
# repro-chunkah-no-systemd-run.sh -- for the two sections of
# crates/ostree-ext/ci/priv-integration.sh (as of upstream bootc
# commit fceedf69) that contain `systemd-run -dP --wait` call sites:
#
#  - lines 103-113 (derived-image build): `podman build`, then two
#    `skopeo copy` calls, each with its `systemd-run -dP --wait`
#    prefix simply deleted.
#  - lines 151-162 (chunkah build): the chunkah `podman run`, again
#    with `systemd-run -dP --wait` deleted, PLUS the `--log-level=debug`
#    / `-e RUST_LOG=chunkah=debug` additions from the accompanying
#    debug-logging commit -- and critically, using the real
#    `--mount=type=image,src=${image},dst=/chunkah` image-mount syntax
#    upstream actually uses, not the `-v host-oci-dir:/chunkah:ro` bind
#    mount substitute the earlier repro scripts used for convenience.
#
# Deviations from the real script, and why (same rationale as
# repro-chunkah-only.sh):
#  - No ostree sysroot/deploy setup (upstream lines 1-102, 115-150):
#    those lines only exercise `ostree admin`/`ostree container image`
#    commands against a real sysroot, none of which are systemd-run
#    call sites and none of which affect (or are affected by) the
#    namespace-escape bug. Skipping them keeps this repro fast and
#    avoids needing a real ostree sysroot under /run/host.
#  - `--prune /sysroot/` in the chunkah invocation still works with no
#    sysroot set up: it refers to a path *inside the rootfs being
#    converted* (under the /chunkah mount), which FCOS images ship as
#    an empty directory by ostree convention. See
#    https://github.com/coreos/chunkah#compatibility-with-bootable-bootc-images
#
# Everything else below is copied verbatim (byte-for-byte, modulo the
# blank-line/comment elision above) from the patched priv-integration.sh.
set -xeuo pipefail
mkdir -p /var/tmp
image=quay.io/fedora/fedora-coreos:testing-devel

date -Iseconds; echo "=== Pulling FCOS image ==="
podman pull ${image}

date -Iseconds; echo "=== Derived image build + skopeo copy (patched upstream lines 103-113) ==="
mkdir build
cd build
cat >Dockerfile << EOF
FROM ${image}
RUN touch /usr/share/somefile
EOF
podman build -t localhost/fcos-derived .
derived_img=oci:/var/tmp/derived.oci
derived_img_dir=dir:/var/tmp/derived.dir
skopeo copy containers-storage:localhost/fcos-derived "${derived_img}"
skopeo copy "${derived_img}" "${derived_img_dir}"
cd ..

date -Iseconds; echo "=== Chunkah build (patched upstream lines 151-162) ==="
nonostree_archive=/var/tmp/nonostree.ociarchive
chunkah_config="$(podman inspect ${image})"
podman --log-level=debug run --rm \
    --mount=type=image,src=${image},dst=/chunkah \
    -v /var/tmp:/output:z \
    -e CHUNKAH_CONFIG_STR="${chunkah_config}" \
    -e RUST_LOG=chunkah=debug \
    quay.io/coreos/chunkah build \
    --prune /sysroot/ \
    --label ostree.commit- \
    --label ostree.final-diffid- \
    -o /output/nonostree.ociarchive

date -Iseconds; echo "=== DONE ==="
ls -lh /var/tmp/derived.oci /var/tmp/derived.dir "${nonostree_archive}"
