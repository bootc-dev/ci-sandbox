#!/bin/bash
# Clean up a sealed application container.
# Called by sealed-httpd.service ExecStop.
set -uo pipefail

: "${SEALED_APP_NAME:?SEALED_APP_NAME not set}"

BUNDLE="/run/sealed-apps/${SEALED_APP_NAME}"

crun delete -f "${SEALED_APP_NAME}" 2>/dev/null || true
umount "${BUNDLE}/rootfs" 2>/dev/null || true
rm -rf "${BUNDLE}"
