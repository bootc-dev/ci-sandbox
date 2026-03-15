#!/bin/bash
# Load the composefs app-signing certificate into the kernel's .fs-verity
# keyring. Called by composefs-load-appkeys.service early in boot.
set -euo pipefail

CERT=/usr/lib/composefs/app-signing-cert.pem

if [ ! -f "${CERT}" ]; then
    echo "composefs: no app signing cert at ${CERT}, skipping keyring load" >&2
    exit 0
fi

cfsctl keyring add-cert "${CERT}"
