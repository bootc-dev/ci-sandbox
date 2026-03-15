#!/bin/bash
# Enable fs-verity built-in signatures and IPE in the CentOS Stream 10
# kernel config files. Run after installing the kernel SRPM.
#
# The c10s kernel ships with:
#   CONFIG_FS_VERITY=y
#   # CONFIG_FS_VERITY_BUILTIN_SIGNATURES is not set
#   # CONFIG_SECURITY_IPE is not set
#
# We enable both, plus the IPE fs-verity property options (auto-selected
# by Kconfig but listed explicitly for clarity).

set -euo pipefail

SOURCES="${HOME}/rpmbuild/SOURCES"

for cfg in "${SOURCES}"/kernel-x86_64-rhel.config \
           "${SOURCES}"/kernel-x86_64-debug-rhel.config; do
    [ -f "$cfg" ] || continue
    echo "Patching: $(basename "$cfg")"

    # fs-verity built-in signature support
    sed -i 's/^# CONFIG_FS_VERITY_BUILTIN_SIGNATURES is not set$/CONFIG_FS_VERITY_BUILTIN_SIGNATURES=y/' "$cfg"

    # IPE LSM
    sed -i 's/^# CONFIG_SECURITY_IPE is not set$/CONFIG_SECURITY_IPE=y/' "$cfg"

    # IPE fs-verity properties (auto-selected when IPE + FS_VERITY are
    # both enabled, but be explicit in case Kconfig ordering matters)
    for opt in CONFIG_IPE_PROP_FS_VERITY \
               CONFIG_IPE_PROP_FS_VERITY_BUILTIN_SIG \
               CONFIG_IPE_PROP_DM_VERITY \
               CONFIG_IPE_PROP_DM_VERITY_SIGNATURE \
               CONFIG_IPE_POLICY_SIG_SECONDARY_KEYRING \
               CONFIG_IPE_POLICY_SIG_PLATFORM_KEYRING; do
        if ! grep -q "^${opt}=" "$cfg"; then
            echo "${opt}=y" >> "$cfg"
        fi
    done

    # IPE boot policy (string option, default empty)
    if ! grep -q "^CONFIG_IPE_BOOT_POLICY=" "$cfg"; then
        echo 'CONFIG_IPE_BOOT_POLICY=""' >> "$cfg"
    fi

    echo "  done"
done
