# Sealed composefs containers: an OCI integrity demo

This demo shows composefs providing end-to-end integrity for OCI
container images — from registry to running workload — using standard
OCI distribution primitives. A CentOS Stream 10 bootc host pulls a
signed application container from GHCR, verifies its composefs PKCS#7
signatures, mounts a read-only filesystem backed by EROFS+overlayfs
with `verity=require`, and runs httpd via crun.

Everything is automated: GitHub Actions seals, signs, and pushes the
app image; the host image embeds the signing certificate and pulls the
app at boot.

## Why this matters

Composefs is becoming a general-purpose OCI integrity layer. Today it
already protects the OS root filesystem on Fedora, CentOS Stream 10,
and other bootc-based systems. This demo extends that model to
arbitrary application containers:

1. **Standard OCI images** — the app is a normal `Containerfile` build.
   Nothing special happens at image-build time.
2. **Post-build sealing** — `cfsctl oci seal` computes fs-verity
   digests for every file and records them in the image metadata.
3. **Detached signatures** — `cfsctl oci sign` creates a PKCS#7
   signature artifact stored as an OCI referrer alongside the image.
   The signature covers the EROFS content digest of the sealed
   filesystem, not just a manifest hash.
4. **Pull-time verification** — `cfsctl oci pull` fetches the image
   via skopeo, then discovers and imports referrer artifacts (signature
   blobs) from the registry using the OCI Referrers API (with a
   tag-scheme fallback for registries like GHCR that don't fully
   implement it).
5. **Mount-time enforcement** — `cfsctl oci mount --require-signature
   --trust-cert` verifies signatures against a trusted certificate
   before mounting. The resulting overlay uses `verity=require`,
   meaning reads from tampered files produce I/O errors.

The result is that an unmodified OCI image, stored in a standard
registry, gets the same composefs integrity guarantees that the OS
root filesystem has — without modifying the image format, the
registry, or the container runtime.

## Architecture

```
 CI (GitHub Actions)
 ├── Build app image (podman build)
 ├── cfsctl oci seal  → compute per-file fs-verity digests
 ├── cfsctl oci sign  → PKCS#7 signature over EROFS content digest
 ├── oras cp -r       → push image + signature referrer to GHCR
 └── Build host image → embed signing cert, systemd services

 Host VM (CentOS Stream 10 bootc)
 ├── composefs-load-appkeys.service
 │     → loads signing cert into kernel .fs-verity keyring
 └── sealed-httpd.service
       ├── cfsctl oci pull   → fetch image + referrer artifacts
       ├── cfsctl oci mount  → verify signature, mount with verity=require
       └── crun run          → httpd on verified rootfs
```

The signature artifacts travel alongside the image as OCI referrers.
On GHCR (which doesn't implement the Referrers API), they're stored
using the OCI 1.1 tag-scheme fallback (`sha256-<digest>` tag). The
`oci-client` crate in cfsctl handles both paths transparently.

## What's in this repo

| File | Purpose |
|---|---|
| `Containerfile.app` | Minimal CentOS Stream 10 httpd container |
| `Containerfile.host` | Bootc host — fetches cfsctl via oras, installs crun, embeds cert |
| `etc/default/sealed-httpd` | Config: image ref, repo path, container name |
| `etc/systemd/system/composefs-load-appkeys.service` | Loads signing cert into kernel keyring |
| `etc/systemd/system/sealed-httpd.service` | Pulls, verifies, mounts, runs the sealed app |
| `usr/lib/composefs/run-sealed-app.sh` | The pull → verify → mount → crun exec flow |
| `usr/lib/composefs/stop-sealed-app.sh` | Cleanup on stop |
| `usr/lib/composefs/load-app-keys.sh` | `cfsctl keyring add-cert` wrapper |
| `.github/workflows/build-sealed.yml` | CI: seal, sign, push app; build, push host |
| `Justfile` | Local dev workflow targets |
| `util/keys.py` | Key generation + GitHub secret storage |

## Running it

### Prerequisites

- podman, openssl, just
- [bcvk](https://github.com/bootc-dev/bcvk) for local VM testing

### Quick start

```
just keygen       # generate composefs signing keypair
just build-app    # build httpd container
just build-host   # build bootc host image (fetches cfsctl from GHCR)
just seal-app     # seal + sign the app image locally
just bcvk-ssh     # boot VM, verify everything works
```

### CI

The GitHub Actions workflow on the `main` branch automates the full
pipeline. It needs two repository secrets (create with
`./util/keys.py github-store`):

- `COMPOSEFS_SIGNING_KEY` — PEM RSA private key
- `COMPOSEFS_SIGNING_CERT` — PEM X.509 certificate

On push to main, the workflow seals, signs, and pushes the app image
to GHCR with referrer artifacts, then builds and pushes the host
image. On PRs, it validates the build with an ephemeral certificate.

### Pre-built images

The CI publishes ready-to-boot images:

```
# Boot the host image directly
bcvk libvirt run --detach --ssh-wait --filesystem=ext4 \
    ghcr.io/cgwalters/ci-sandbox/sealed-host:latest
```

The host pulls `ghcr.io/cgwalters/ci-sandbox/sealed-app:latest` at
boot, verifies its signatures, and serves the demo page on port 80.

## How cfsctl is built

The composefs-rs source lives on the `composefs` branch of this repo.
A separate workflow (`build-cfsctl-artifact.yml`) builds cfsctl in
release mode with `--features composefs/rhel9,composefs-oci/oci-client`
and pushes the binary as an OCI artifact to
`ghcr.io/cgwalters/ci-sandbox/cfsctl:composefs`. Both the CI workflow
and the host Containerfile fetch this artifact via oras — no Rust
toolchain needed at image build time.

The `rhel9` feature enables loopback device support for mounting EROFS
images on kernels that don't support direct file-backed EROFS mounts
(CentOS Stream 10's 6.12 kernel). The `oci-client` feature enables
fetching referrer artifacts from registries via the OCI Referrers API
(with tag-scheme fallback).

## Current limitations

**Userspace signature verification only.** CentOS Stream 10's kernel
has `CONFIG_FS_VERITY=y` but `CONFIG_FS_VERITY_BUILTIN_SIGNATURES` is
not set. Signatures are verified by cfsctl before mounting (userspace
PKCS#7 check), not enforced by the kernel at the VFS layer. A custom
kernel with `CONFIG_FS_VERITY_BUILTIN_SIGNATURES=y` would close this
gap.

**`--insecure` flag.** The demo passes `--insecure` to cfsctl, which
skips enabling fs-verity on individual object files. The composefs
overlay still uses `verity=require` for the mount itself. Dropping
`--insecure` requires a filesystem that supports fs-verity (ext4 or
f2fs with the feature enabled) and appropriate permissions.

**Single-arch.** The cfsctl OCI artifact and demo images are x86_64
only.

---

🤖 Assisted-by: OpenCode (Claude Opus 4)
