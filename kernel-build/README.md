# Custom Kernel Build: composefs-IPE integration

This builds a CentOS Stream 10 kernel RPM with composefs-IPE integration
patches and additional security config options enabled.

## What gets enabled

Config overrides (via `kernel-local`):

- **`CONFIG_FS_VERITY_BUILTIN_SIGNATURES`** — kernel-level verification of
  fs-verity file digests against built-in X.509 certificates
- **`CONFIG_SECURITY_IPE`** — Integrity Policy Enforcement LSM
- **`CONFIG_IPE_PROP_OVL_VERITY`** — IPE property for overlay verity validation
  (from our patches below)

## Patches

Two kernel patches wire up composefs/overlayfs to IPE:

1. **`0001-overlayfs-lsm-Notify-LSMs-when-overlay-verity-valida.patch`** —
   adds `LSM_INT_OVL_VERITY_VALIDATED` and calls `security_inode_setintegrity()`
   after overlayfs successfully validates a metacopy file's fs-verity digest.

2. **`0002-ipe-Add-overlay_verity_validated-property-for-compos.patch`** —
   adds the `overlay_verity_validated=TRUE/FALSE` property to IPE policies,
   letting admins write rules like:
   ```
   op=EXECUTE overlay_verity_validated=TRUE action=ALLOW
   ```

Together these enable the composefs trust chain: a signed EROFS metadata
image records per-file fs-verity digests, overlayfs enforces them with
`verity=require`, and IPE gates execution based on that verification.

## Build approach

This works as a **dist-git overlay** on top of the c10s kernel SRPM:

- **Patches** are registered via the spec's `# END OF PATCH DEFINITIONS`
  and `# END OF PATCH APPLICATIONS` sentinel comments (the same mechanism
  the distro uses for `linux-kernel-test.patch`)
- **Config** is injected via `kernel-local` (Source3001), the distro's
  intended user-override file — no need to modify arch-specific configs
- **Build ID** is set to `.fsverity` to distinguish from stock

## Building

```sh
just build
```

Runs a multi-stage container build (~30-60 minutes) and extracts RPMs
into `out/`.

## Using the output

Install into a bootc container image:

```dockerfile
COPY out/kernel-core-*.rpm out/kernel-modules-*.rpm /tmp/rpms/
RUN dnf install -y /tmp/rpms/*.rpm && rm -rf /tmp/rpms/
```
