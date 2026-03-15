# Custom Kernel Build: fs-verity + IPE

This builds a CentOS Stream 10 kernel RPM with additional security config
options enabled that are not on by default in the distribution kernel.

## What gets enabled

- **`CONFIG_FS_VERITY_BUILTIN_SIGNATURES`** — allows the kernel to verify
  fs-verity file digests against built-in X.509 certificates. This is the
  foundation for content-trust at the filesystem level.
- **`CONFIG_SECURITY_IPE`** — Integrity Policy Enforcement, a Linux Security
  Module that can enforce policies based on file integrity properties
  (including fs-verity).
- **`CONFIG_IPE_PROP_FS_VERITY`** / **`CONFIG_IPE_PROP_FS_VERITY_BUILTIN_SIG`**
  — IPE policy properties for fs-verity digest and signature checks.

## Why

The stock CentOS Stream 10 kernel has `CONFIG_FS_VERITY=y` but does not enable
the built-in signature support or IPE. These are needed for composefs-based
integrity enforcement where the system verifies file content against known
fs-verity digests at open time.

## Building

```sh
just build
```

This runs a multi-stage container build (~30-60 minutes depending on hardware)
and extracts the resulting RPMs into `out/`.

## Using the output

The `out/` directory will contain `kernel-*.rpm` packages. Install them into a
bootc container image via `rpm-ostree install` or `dnf install` in your
Containerfile:

```dockerfile
COPY out/kernel-core-*.rpm out/kernel-modules-*.rpm /tmp/rpms/
RUN dnf install -y /tmp/rpms/*.rpm && rm -rf /tmp/rpms/
```

Or push them as an OCI artifact for later consumption:

```sh
just push
```
