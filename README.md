# Sealed composefs containers: an OCI integrity demo

This demo shows two layers of composefs integrity on a CentOS Stream 10
bootc system:

1. **Sealed host root** — the bootc host itself boots with the composefs
   backend. A Unified Kernel Image (UKI) embeds the composefs digest of
   the root filesystem, signed with Secure Boot keys. At boot, every
   file is verified against its fs-verity digest.

2. **Sealed application containers** — a signed httpd container is
   pulled from GHCR, its composefs PKCS#7 signatures are verified, and
   it runs on a read-only overlay with `verity=require`.

Everything is automated: GitHub Actions builds, seals, signs, and
pushes both the host and app images.

## Why this matters

Composefs provides end-to-end integrity from firmware to userspace:

- **Secure Boot** → trusts the signed UKI
- **UKI cmdline** → contains `composefs=<sha512-digest>` of the root
- **composefs** → verifies every file's fs-verity digest at open time
- **IPE** (with our kernel patches) → gates execution on overlay verity
  validation

For application containers, the same trust chain extends via cfsctl:
standard OCI images get sealed post-build, signed with detached PKCS#7
artifacts stored as OCI referrers, and verified at mount time.

## Architecture

```
 CI (GitHub Actions)
 ├── Build app image (podman build)
 ├── cfsctl oci seal  → compute per-file fs-verity digests
 ├── cfsctl oci sign  → PKCS#7 signature over EROFS content digest
 ├── oras cp -r       → push image + signature referrer to GHCR
 └── Build host image
       ├── bootc container compute-composefs-digest → SHA-512 of rootfs
       ├── ukify build --cmdline "composefs=<digest>" → signed UKI
       └── Secure Boot signing with --secret sb-db.key

 Host VM (CentOS Stream 10 bootc, composefs root)
 ├── composefs-load-appkeys.service
 │     → loads signing cert into kernel .fs-verity keyring
 └── sealed-httpd.service
       ├── cfsctl oci pull   → fetch image + referrer artifacts
       ├── cfsctl oci mount  → verify signature, mount with verity=require
       └── crun run          → httpd on verified rootfs
```

## What's in this repo

| File | Purpose |
|---|---|
| `Containerfile.host` | Sealed bootc host — composefs digest, signed UKI, app services |
| `Containerfile.app` | Minimal CentOS Stream 10 httpd container |
| `keys/` | **Public** Secure Boot and app-signing certificates (commit these) |
| `kernel-build/` | Custom kernel with composefs-IPE patches |
| `etc/systemd/system/` | Systemd services for app keyring + sealed httpd |
| `usr/lib/composefs/` | Shell scripts for the pull → verify → mount → exec flow |
| `.github/workflows/build-sealed.yml` | CI pipeline |
| `Justfile` | Local dev workflow |
| `util/keys.py` | Key generation + GitHub secret storage |

## Running it

### Prerequisites

- podman, openssl, just
- [bcvk](https://github.com/bootc-dev/bcvk) for local VM testing

### Quick start

```
just keygen       # generate all keypairs (composefs + Secure Boot)
just build-app    # build httpd container
just build-host   # build sealed bootc host (composefs backend)
just seal-app     # seal + sign the app image locally
just bcvk-ssh     # boot VM with Secure Boot keys, verify everything
```

### CI

The GitHub Actions workflow needs these repository secrets (create with
`python3 util/keys.py github-store --repo OWNER/REPO --generate`):

- `COMPOSEFS_SIGNING_KEY` / `COMPOSEFS_SIGNING_CERT` — app signing
- `SECUREBOOT_DB_KEY` / `SECUREBOOT_DB_CERT` — Secure Boot db key

The public certs go in `keys/` and should be committed to the repo.

### Pre-built images

```
bcvk libvirt run --detach --ssh-wait \
    --filesystem=ext4 \
    --secure-boot-keys target/keys \
    ghcr.io/bootc-dev/ci-sandbox/sealed-host:latest
```

## Kernel patches (kernel-build/)

Two kernel patches wire up composefs/overlayfs to IPE (Integrity Policy
Enforcement), enabling policies like:

```
op=EXECUTE overlay_verity_validated=TRUE action=ALLOW
```

See `kernel-build/README.md` for details. The build uses a dist-git
overlay approach: patches + `kernel-local` config are injected into the
c10s kernel SRPM at build time.

## Current limitations

- **Custom kernel required for IPE.** The stock c10s kernel doesn't have
  `CONFIG_SECURITY_IPE` or `CONFIG_FS_VERITY_BUILTIN_SIGNATURES`. The
  `kernel-build/` produces RPMs with these enabled plus the composefs-IPE
  patches, but they're not yet wired into the host Containerfile.
- **Single-arch.** x86_64 only.

---

Assisted-by: OpenCode (Claude Opus 4)
