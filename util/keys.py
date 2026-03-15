#!/usr/bin/env python3
"""Generate and store signing keys for the sealed composefs demo.

Usage:
    keys.py generate [--output-dir DIR]
    keys.py github-store --repo OWNER/REPO [--keys-dir DIR]
    keys.py github-store --repo OWNER/REPO --generate

The 'generate' verb creates all required key material:
  - Composefs app-signing keypair (RSA-4096, 10-year cert)
  - Cosign keypair (ECDSA P-256)
  - Secure Boot keys (PK, KEK, db — RSA-2048, 10-year certs)

The 'github-store' verb uploads them as GitHub Actions secrets
using the 'gh' CLI.  Pass --generate to do both in one step.
"""

import argparse
import os
import subprocess
import sys
import uuid
from pathlib import Path

DEFAULT_KEYS_DIR = "target/keys"

# Map of secret name -> (filename, description)
SECRETS = {
    "COMPOSEFS_SIGNING_KEY": (
        "composefs-signing.key",
        "Composefs app-signing private key",
    ),
    "COMPOSEFS_SIGNING_CERT": (
        "composefs-signing.pem",
        "Composefs app-signing certificate",
    ),
    "COSIGN_KEY": ("cosign.key", "Cosign ECDSA private key"),
    "COSIGN_PUB": ("cosign.pub", "Cosign ECDSA public key"),
    "SECUREBOOT_PK_KEY": ("sb-PK.key", "Secure Boot Platform Key (private)"),
    "SECUREBOOT_PK_CERT": ("sb-PK.crt", "Secure Boot Platform Key (cert)"),
    "SECUREBOOT_KEK_KEY": ("sb-KEK.key", "Secure Boot KEK (private)"),
    "SECUREBOOT_KEK_CERT": ("sb-KEK.crt", "Secure Boot KEK (cert)"),
    "SECUREBOOT_DB_KEY": ("sb-db.key", "Secure Boot db (private)"),
    "SECUREBOOT_DB_CERT": ("sb-db.crt", "Secure Boot db (cert)"),
    "SECUREBOOT_GUID": ("sb-guid.txt", "Secure Boot owner GUID"),
}


def run(cmd, **kwargs):
    """Run a command, raising on failure."""
    return subprocess.run(cmd, check=True, **kwargs)


def openssl(*args):
    run(["openssl", *args], stdout=subprocess.DEVNULL)


def generate_keys(output_dir: Path):
    """Generate all key material."""
    output_dir.mkdir(parents=True, exist_ok=True)

    # -- Composefs app-signing (RSA-4096) --
    key = output_dir / "composefs-signing.key"
    cert = output_dir / "composefs-signing.pem"
    if key.exists():
        print(f"  skip  {key} (already exists)")
    else:
        print(f"  create composefs-signing keypair")
        openssl(
            "req",
            "-x509",
            "-newkey",
            "rsa:4096",
            "-nodes",
            "-keyout",
            str(key),
            "-out",
            str(cert),
            "-days",
            "3650",
            "-subj",
            "/CN=composefs-app-signing/O=composefs-demo",
        )

    # -- Cosign (ECDSA P-256) --
    cosign_key = output_dir / "cosign.key"
    cosign_pub = output_dir / "cosign.pub"
    if cosign_key.exists():
        print(f"  skip  {cosign_key} (already exists)")
    else:
        print(f"  create cosign keypair (ECDSA P-256)")
        openssl(
            "genpkey",
            "-algorithm",
            "EC",
            "-pkeyopt",
            "ec_paramgen_curve:prime256v1",
            "-out",
            str(cosign_key),
        )
        openssl("pkey", "-in", str(cosign_key), "-pubout", "-out", str(cosign_pub))

    # -- Secure Boot (PK, KEK, db — RSA-2048) --
    guid_file = output_dir / "sb-guid.txt"
    if guid_file.exists():
        print(f"  skip  {guid_file} (already exists)")
    else:
        guid = str(uuid.uuid4())
        guid_file.write_text(guid + "\n")
        print(f"  create SB GUID: {guid}")

    for name in ("PK", "KEK", "db"):
        sb_key = output_dir / f"sb-{name}.key"
        sb_crt = output_dir / f"sb-{name}.crt"
        if sb_key.exists():
            print(f"  skip  {sb_key} (already exists)")
            continue
        print(f"  create sb-{name} keypair")
        openssl(
            "req",
            "-new",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(sb_key),
            "-out",
            str(sb_crt),
            "-days",
            "3650",
            "-subj",
            f"/CN=composefs-demo {name}",
        )

    print(f"\nKeys written to {output_dir}/")


def github_store(repo: str, keys_dir: Path):
    """Upload key material as GitHub Actions secrets."""
    # Verify gh is available
    try:
        run(["gh", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        print(
            "error: 'gh' CLI not found. Install from https://cli.github.com/",
            file=sys.stderr,
        )
        sys.exit(1)

    missing = []
    for secret_name, (filename, _desc) in SECRETS.items():
        path = keys_dir / filename
        if not path.exists():
            missing.append(str(path))
    if missing:
        print(f"error: missing key files:\n  " + "\n  ".join(missing), file=sys.stderr)
        print(
            f"\nRun '{sys.argv[0]} generate --output-dir {keys_dir}' first.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Storing {len(SECRETS)} secrets on {repo}...\n")
    for secret_name, (filename, desc) in SECRETS.items():
        path = keys_dir / filename
        value = path.read_text()
        print(f"  {secret_name:30s} <- {filename}")
        run(
            ["gh", "secret", "set", secret_name, "--repo", repo, "--body", value],
            stdout=subprocess.DEVNULL,
        )

    print(f"\nDone. {len(SECRETS)} secrets stored on {repo}.")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # -- generate --
    gen = sub.add_parser("generate", help="Generate all signing keys")
    gen.add_argument(
        "--output-dir",
        type=Path,
        default=Path(DEFAULT_KEYS_DIR),
        help=f"Directory to write keys to (default: {DEFAULT_KEYS_DIR})",
    )

    # -- github-store --
    store = sub.add_parser("github-store", help="Upload keys as GHA secrets")
    store.add_argument("--repo", required=True, help="GitHub repo (owner/repo)")
    store.add_argument(
        "--keys-dir",
        type=Path,
        default=Path(DEFAULT_KEYS_DIR),
        help=f"Directory containing keys (default: {DEFAULT_KEYS_DIR})",
    )
    store.add_argument(
        "--generate",
        action="store_true",
        dest="do_generate",
        help="Generate keys first if they don't exist",
    )

    args = parser.parse_args()

    if args.command == "generate":
        print("Generating key material...\n")
        generate_keys(args.output_dir)

    elif args.command == "github-store":
        if args.do_generate:
            print("Generating key material...\n")
            generate_keys(args.keys_dir)
            print()
        github_store(args.repo, args.keys_dir)


if __name__ == "__main__":
    main()
