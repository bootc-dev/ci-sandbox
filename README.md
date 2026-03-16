# Sealed composefs containers: an OCI integrity demo

This demo shows two layers of composefs integrity on a CentOS Stream 10
bootc system:

1. **Sealed host root** — the bootc host boots with the composefs
   backend. A Unified Kernel Image (UKI) embeds the composefs digest of
   the root filesystem, signed with Secure Boot keys. At boot, every
   file is verified against its fs-verity digest.

2. **Sealed application containers** — a signed httpd container is
   pulled from GHCR, its composefs PKCS#7 signatures are verified, and
   it runs on a read-only overlay with `verity=require`.

## Trying it with bcvk

### 1. Generate Secure Boot keys

```sh
python3 util/keys.py generate --output-dir target/keys
```

This creates `target/keys/` with PK, KEK, db keypairs plus composefs
signing keys. bcvk requires the files named `PK.crt`, `KEK.crt`,
`db.crt`, and `GUID.txt`, so create the symlinks it expects:

```sh
cd target/keys
ln -sf sb-PK.crt PK.crt
ln -sf sb-PK.key PK.key
ln -sf sb-KEK.crt KEK.crt
ln -sf sb-KEK.key KEK.key
ln -sf sb-db.crt db.crt
ln -sf sb-db.key db.key
cp sb-guid.txt GUID.txt
cd -
```

You'll also need `virt-fw-vars` for Secure Boot key enrollment
into OVMF:

```sh
pip install virt-firmware
```

### 2. Build the sealed host image

The app-signing public cert needs to be available at build time
(it gets embedded in the image for loading into the kernel keyring):

```sh
cp target/keys/composefs-signing.pem app-signing-cert.pem

podman build -f Containerfile.host \
  --secret id=secureboot_key,src=target/keys/sb-db.key \
  --secret id=secureboot_cert,src=target/keys/sb-db.crt \
  -t localhost/sealed-host:latest .

rm app-signing-cert.pem
```

### 3. Boot with bcvk

```sh
bcvk libvirt run --detach --name sealed-demo \
  --composefs-backend \
  --secure-boot-keys target/keys \
  localhost/sealed-host:latest
```

Wait ~3 minutes for first boot (host key generation is slow), then:

```sh
bcvk libvirt ssh sealed-demo
```

### 4. Verify composefs root

Inside the VM:

```sh
# Root is composefs with verity=require
mount | grep ' / '
# composefs:8c199e5d... on / type overlay (ro,verity=require)

cat /proc/cmdline
# composefs=8c199e5d... rw enforcing=0 ...

cfsctl --version
# cfsctl 0.3.0

getenforce
# Permissive
```

### 5. Clean up

```sh
bcvk libvirt rm --stop --force sealed-demo
```

## Architecture

```
 Build time
 ├── Containerfile.host
 │     ├── Install packages (crun, systemd-boot, cfsctl)
 │     ├── Sign systemd-boot with Secure Boot db key
 │     ├── Rebuild initramfs with bootc dracut module
 │     └── FROM scratch flatten (deterministic composefs digest)
 ├── bootc container ukify
 │     ├── Compute composefs SHA-512 digest from flattened rootfs
 │     ├── Embed digest + kargs in UKI cmdline
 │     └── Sign UKI with Secure Boot db key (sbsign)
 └── COPY --from=kernel /boot /boot (UKI goes to ESP, not rootfs)

 Boot time (UEFI → systemd-boot → UKI → composefs)
 ├── UEFI verifies systemd-boot signature against enrolled db
 ├── systemd-boot loads UKI from /EFI/Linux/bootc/<digest>.efi
 ├── Kernel starts with composefs=<digest> in cmdline
 ├── initramfs: bootc-root-setup.service
 │     ├── Mounts ext4 root partition
 │     ├── Opens composefs repository at composefs/
 │     ├── Mounts EROFS metadata image (composefs image)
 │     ├── Sets up overlayfs with verity=require
 │     └── Bind-mounts /etc and /var from state/deploy/<digest>/
 └── switch-root into composefs overlay
```

## What's in this repo

| Path | Purpose |
|---|---|
| `Containerfile.host` | Sealed bootc host with composefs backend |
| `Containerfile.app` | Minimal CentOS Stream 10 httpd container |
| `kernel-build/` | Custom kernel with composefs-IPE patches |
| `etc/systemd/system/` | Systemd services for app keyring + sealed httpd |
| `usr/lib/composefs/` | Scripts for pull → verify → mount → exec flow |
| `.github/workflows/` | CI pipeline |
| `Justfile` | Local dev workflow |
| `util/keys.py` | Key generation + GitHub secret storage |

## Key learnings from getting this working

- The rootfs must be flattened to a single layer (`FROM scratch` +
  `COPY --from=`) for deterministic composefs digests
  ([composefs-rs#132](https://github.com/containers/composefs-rs/issues/132)).

- `rw` must be in the kernel cmdline so the backing ext4 is mounted
  read-write (needed for `/etc` and `/var` bind mounts from state).

- The `51bootc` dracut module must be explicitly added via
  `dracut.conf.d` and the initramfs rebuilt — its `check()` returns
  255 so it's never auto-included.

- systemd-boot must be signed with the Secure Boot db key (the stock
  `systemd-boot-unsigned` RPM is unsigned). Sign it before the
  `FROM scratch` flatten so it's included in the composefs digest.

- SELinux must be permissive (`enforcing=0`) for composefs boot
  ([bootc#1826](https://github.com/bootc-dev/bootc/issues/1826)).

- First boot takes ~3 minutes because sshd-keygen runs late.
  Subsequent boots are fast.

## CI secrets

The GitHub Actions workflow needs these secrets:

| Secret | Source file | Description |
|---|---|---|
| `COMPOSEFS_SIGNING_KEY` | `composefs-signing.key` | App signing private key |
| `COMPOSEFS_SIGNING_CERT` | `composefs-signing.pem` | App signing certificate |
| `SECUREBOOT_DB_KEY` | `sb-db.key` | Secure Boot db private key |
| `SECUREBOOT_DB_CERT` | `sb-db.crt` | Secure Boot db certificate |

Generate and upload with:
```sh
python3 util/keys.py github-store --repo OWNER/REPO --generate
```

## Kernel patches (kernel-build/)

Two kernel patches wire up composefs/overlayfs to IPE (Integrity Policy
Enforcement), enabling policies like:

```
op=EXECUTE overlay_verity_validated=TRUE action=ALLOW
```

See `kernel-build/README.md` for details.

## Current limitations

- **SELinux must be permissive.** Composefs content-store objects get
  `unlabeled_t` labels; a policy module or relabeling is needed.
- **Custom kernel required for IPE.** The stock c10s kernel doesn't have
  `CONFIG_SECURITY_IPE`. The `kernel-build/` produces RPMs with it
  enabled plus the composefs-IPE patches.
- **x86_64 only.**

---

Assisted-by: OpenCode (Claude Opus 4)
