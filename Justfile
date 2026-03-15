# Justfile for sealed composefs demo
#
# Builds a CentOS Stream 10 bootc host with composefs app-signing keys
# and a sealed httpd application container verified at mount time.
#
# CentOS Stream 10 bootc already includes composefs support (dracut module,
# composefs-setup-root, SELinux policy, systemd-networkd). We add cfsctl
# (built from source inside the container build), crun, and the app-signing
# certificate.
#
# Prerequisites: podman, openssl, just
# For sealing: cargo (builds cfsctl locally for the seal-app step)
# For VM testing: bcvk (from bootc-dev/bcvk)

# Path to composefs-rs source tree (for local cfsctl builds used in seal-app)
composefs_src := env("COMPOSEFS_SRC", justfile_directory() + "/../../..")

# Local image names
host_image := "localhost/sealed-host:latest"
app_image := "localhost/sealed-app:latest"

# Key material and build artifacts
keys_dir := justfile_directory() + "/target/keys"

# Generate composefs signing keypair
keygen:
    #!/bin/bash
    set -euo pipefail
    mkdir -p "{{keys_dir}}"
    if [ -f "{{keys_dir}}/composefs-signing.key" ]; then
        echo "Signing keypair already exists in {{keys_dir}}, skipping"
        exit 0
    fi
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout "{{keys_dir}}/composefs-signing.key" \
        -out "{{keys_dir}}/composefs-signing.pem" \
        -days 3650 -subj '/CN=composefs-app-signing/O=composefs-demo'
    echo "Generated composefs signing keypair in {{keys_dir}}"

# Build cfsctl from composefs-rs source (for local seal/sign operations)
build-cfsctl:
    cargo build --release --manifest-path "{{composefs_src}}/Cargo.toml" \
        -p cfsctl --features composefs-oci/oci-client

# Build the sealed host image
#
# cfsctl is built from source INSIDE the container build (multi-stage).
# By default clones from cgwalters/ci-sandbox composefs branch; override
# with COMPOSEFS_RS_REPO/COMPOSEFS_RS_REF env vars for local dev.
build-host: keygen
    #!/bin/bash
    set -euo pipefail
    cp "{{keys_dir}}/composefs-signing.pem" app-signing-cert.pem
    podman build -f Containerfile.host \
        -t "{{host_image}}" .
    rm -f app-signing-cert.pem
    echo "Host image built: {{host_image}}"

# Build the httpd application image
build-app:
    podman build -f Containerfile.app -t "{{app_image}}" .
    echo "App image built: {{app_image}}"

# Seal and sign the app image with composefs keys
seal-app: keygen build-cfsctl build-app
    #!/bin/bash
    set -euo pipefail
    CFSCTL="{{composefs_src}}/target/release/cfsctl"
    REPO="{{justfile_directory()}}/target/composefs-repo"

    echo "Initializing composefs repo..."
    "${CFSCTL}" --insecure --repo "${REPO}" init

    echo "Pulling app image into composefs repo..."
    IMAGE_ID=$(podman inspect --format '{''{''.Id}''}' "{{app_image}}")
    "${CFSCTL}" --insecure --repo "${REPO}" oci pull "containers-storage:${IMAGE_ID}" sealed-app

    echo "Sealing app image..."
    "${CFSCTL}" --insecure --repo "${REPO}" oci seal sealed-app

    echo "Signing sealed app image..."
    "${CFSCTL}" --insecure --repo "${REPO}" oci sign sealed-app \
        --cert "{{keys_dir}}/composefs-signing.pem" \
        --key "{{keys_dir}}/composefs-signing.key"

    echo "Verifying signature..."
    "${CFSCTL}" --insecure --repo "${REPO}" oci verify sealed-app \
        --cert "{{keys_dir}}/composefs-signing.pem"

    echo "App image sealed and signed successfully"

# Boot a VM and verify the sealed app service works e2e.
# Uses default ostree boot mode (--composefs-backend is not yet reliable).
bcvk-ssh: build-host
    #!/bin/bash
    set -euo pipefail

    VM_NAME="sealed-demo"

    # Clean up any previous VM with this name
    bcvk libvirt rm --stop --force "${VM_NAME}" 2>/dev/null || true

    echo "==> Booting sealed host VM..."
    bcvk libvirt run --detach --ssh-wait --name "${VM_NAME}" \
        --filesystem=ext4 \
        "{{host_image}}"

    echo "==> Waiting for multi-user.target (timeout 120s)..."
    bcvk libvirt ssh "${VM_NAME}" -- \
        timeout 120 bash -c \
            'systemctl is-active multi-user.target || journalctl -b --no-pager -o cat UNIT=multi-user.target --follow | grep -q -m1 "Reached target"'

    echo "==> multi-user.target reached, running checks..."
    bcvk libvirt ssh "${VM_NAME}" -- bash -c '
        set -euo pipefail
        failed=0

        echo "--- cfsctl version ---"
        cfsctl --version

        echo "--- composefs-load-appkeys.service ---"
        if systemctl is-active --quiet composefs-load-appkeys.service; then
            echo "  OK: keyring service active"
        else
            echo "  FAIL: keyring service not active"
            systemctl status composefs-load-appkeys.service --no-pager || true
            journalctl -b -u composefs-load-appkeys.service --no-pager || true
            failed=1
        fi

        echo "--- sealed-httpd.service ---"
        if systemctl is-active --quiet sealed-httpd.service; then
            echo "  OK: sealed-httpd active"
            # Verify httpd is actually serving
            if curl -sf http://localhost/ | grep -q "sealed"; then
                echo "  OK: httpd serving sealed demo page"
            else
                echo "  WARN: httpd active but page content unexpected"
            fi
        else
            echo "  FAIL: sealed-httpd not active"
            systemctl status sealed-httpd.service --no-pager || true
            journalctl -b -u sealed-httpd.service --no-pager || true
            failed=1
        fi

        if [ "$failed" -eq 0 ]; then
            echo ""
            echo "=== ALL CHECKS PASSED ==="
        else
            echo ""
            echo "=== SOME CHECKS FAILED (see above) ==="
            exit 1
        fi
    '

    echo "==> Cleaning up VM..."
    bcvk libvirt rm --stop --force "${VM_NAME}"
    echo "Done."

# Build everything end-to-end
all: build-host build-app seal-app

# Clean generated artifacts and VM
clean:
    #!/bin/bash
    set -euo pipefail
    bcvk libvirt rm --stop --force sealed-demo 2>/dev/null || true
    rm -rf target/ app-signing-cert.pem
    podman rmi -f "{{host_image}}" "{{app_image}}" 2>/dev/null || true
    echo "Cleaned"
