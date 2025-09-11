#!/bin/bash
set -exuo pipefail

# You must have invoked test/build.sh before running this.

# Put ourself in a user+mount+pid namespace to close leaks
# TODO: debug why this doesn't work on Ubuntu
#if test -z "${test_unshared:-}"; then
#  exec unshare -Umr -- env test_unshared=1 "$0" "$@"
#fi

# Ensure we're in the topdir canonically
cd $(git rev-parse --show-toplevel)

DISK=target/integration-test.raw

# Generate a temporary key
SSH_KEY=$(pwd)/target/id_rsa
rm -vf "${SSH_KEY}"*
ssh-keygen -f "${SSH_KEY}" -N "" -q -t rsa-sha2-256 -b 4096
chmod 600 "${SSH_KEY}"

TMT_PLAN_NAME=$1
shift

SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o PasswordAuthentication=no -o ConnectTimeout=5)
pubkey=$(base64 -w 0 < target/id_rsa.pub)
ssh_tmpfiles=$(printf "d /root/.ssh 0750 - - -\nf+~ /root/.ssh/authorized_keys 700 - - - ${pubkey}" | base64 -w 0)
ssh_cred="io.systemd.credential.binary:tmpfiles.extra="${ssh_tmpfiles}

# TODO replace with tmt's virt provisioner
ARCH=$(uname -m)
qemu_args=()
case "$ARCH" in
"aarch64")
  qemu_args+=(qemu-system-aarch64
    -machine virt
    -bios /usr/share/AAVMF/AAVMF_CODE.fd)
  ;;
"x86_64")
  qemu_args+=(qemu-system-x86_64)
  ;;
*)
  echo "Unhandled architecture: $ARCH" >&2
  exit 1
  ;;
esac
qemu_args+=(
    -name bootc-vm
    -enable-kvm
    -cpu host
    -m 2G
    -drive file="target/disk.raw",if=virtio,format=raw
    -snapshot
    -net nic,model=virtio
    -net user,hostfwd=tcp::2222-:22
    -display none
    -smbios type=11,value=${ssh_cred}
)

# Kill qemu when the test exits by default
setpriv --pdeathsig SIGTERM -- ${qemu_args[@]} &>/dev/null &

wait_for_ssh_up() {
  SSH_STATUS=$(ssh "${SSH_OPTIONS[@]}" -i "$SSH_KEY" -p 2222 root@"${1}" '/bin/bash -c "echo -n READY"')
  if [[ $SSH_STATUS == READY ]]; then
    echo 1
  else
    echo 0
  fi
}

for _ in $(seq 0 30); do
  RESULT=$(wait_for_ssh_up "localhost")
  if [[ $RESULT == 1 ]]; then
    echo "SSH is ready now! 🥳"
    break
  fi
  sleep 10
done

# Make sure VM is ready for testing
ssh "${SSH_OPTIONS[@]}" \
  -i "$SSH_KEY" \
  -p 2222 \
  root@localhost \
  "bootc status"

# Move the tmt bits to a subdirectory to work around https://github.com/teemtee/tmt/issues/4062
rm target/tmt-workdir -rf
mkdir target/tmt-workdir
cp -a .fmf tmt target/tmt-workdir/
cd target/tmt-workdir
# TMT will rsync tmt-* scripts to TMT_SCRIPTS_DIR=/var/lib/tmt/scripts
tmt run --all --verbose -e TMT_SCRIPTS_DIR=/var/lib/tmt/scripts provision --how connect --guest localhost --port 2222 --user root --key "$SSH_KEY" plan --name "/tmt/plans/integration/${TMT_PLAN_NAME}"
