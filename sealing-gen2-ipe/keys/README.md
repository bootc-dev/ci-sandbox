# Public Keys

This directory contains the **public** Secure Boot and composefs signing
certificates for the sealed demo. Private keys are stored as GitHub
Actions secrets and never committed.

## Files

- `sb-db.crt` — Secure Boot db certificate. Enroll this in your
  firmware's Secure Boot db to trust UKIs signed by this demo.
- `app-signing-cert.pem` — composefs app-signing certificate. Loaded
  into the kernel's `.fs-verity` keyring at boot to verify sealed
  application container filesystems.

## Key generation

Generate all keys (public + private) locally:

```sh
python3 util/keys.py generate
```

Upload private keys as GitHub Actions secrets:

```sh
python3 util/keys.py github-store --repo OWNER/REPO
```

The public certs should then be copied here and committed:

```sh
cp target/keys/sb-db.crt keys/
cp target/keys/composefs-signing.pem keys/app-signing-cert.pem
```
