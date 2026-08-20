#!/bin/bash
# Dump diagnostics about the host and any nested podman/outer bootc
# container, for use by a watchdog that suspects a hung chunkah/podman
# step (see repro-chunkah-hang.yml and the AGENTS.md investigation notes
# for bootc PR #2394). Safe to run repeatedly; read-only except for the
# strace snippet which attaches/detaches briefly.
set -x
date -Iseconds
echo "=== ps auxf ==="
ps auxf
echo "=== sudo podman ps -a --no-trunc ==="
sudo podman ps -a --no-trunc
echo "=== df -h ==="
df -h
echo "=== du -sh /var/tmp/* ==="
du -sh /var/tmp/* 2>/dev/null
echo "=== dmesg tail ==="
sudo dmesg | tail -100
echo "=== dmesg oom/kill/overlay/fuse/cgroup/error ==="
sudo dmesg | grep -iE 'oom|kill|overlay|fuse|cgroup|error' || true
echo "=== systemctl list-units run-* ==="
systemctl list-units 'run-*' --no-pager || true
echo "=== journalctl libpod-* tail ==="
sudo journalctl -u 'libpod-*' --no-pager 2>/dev/null | tail -50
echo "=== ip netns list ==="
sudo ip netns list || true
echo "=== podman network ls (host) ==="
sudo podman network ls || true

OUTER_ID=$(sudo podman ps -a --format '{{.ID}} {{.Image}}' | grep -m1 bootc | awk '{print $1}')
if [ -n "${OUTER_ID:-}" ]; then
  OUTER_PID=$(sudo podman inspect -f '{{.State.Pid}}' "$OUTER_ID")
  echo "=== outer container: id=$OUTER_ID pid=$OUTER_PID ==="
  if [ -n "$OUTER_PID" ] && [ "$OUTER_PID" != "0" ]; then
    echo "=== nsenter ps auxf ==="
    sudo nsenter -t "$OUTER_PID" -m -u -i -n -p -- ps auxf || true
    echo "=== nsenter podman ps -a --no-trunc ==="
    sudo nsenter -t "$OUTER_PID" -m -u -i -n -p -- podman ps -a --no-trunc || true
    echo "=== nsenter systemctl list-units run-* ==="
    sudo nsenter -t "$OUTER_PID" -m -u -i -n -p -- systemctl list-units 'run-*' --no-pager || true
    echo "=== nsenter ls -la /var/tmp ==="
    sudo nsenter -t "$OUTER_PID" -m -u -i -n -p -- ls -la /var/tmp/ || true

    # If a specific process looks stuck, grab a few seconds of strace on it.
    STUCK_PID=$(sudo nsenter -t "$OUTER_PID" -m -u -i -n -p -- ps -eo pid,comm --no-headers \
      | grep -m1 -E 'podman|skopeo|conmon|chunkah' | awk '{print $1}')
    if [ -n "${STUCK_PID:-}" ]; then
      echo "=== strace -p $STUCK_PID for 5s (via nsenter) ==="
      sudo nsenter -t "$OUTER_PID" -m -u -i -n -p -- \
        timeout 5 strace -p "$STUCK_PID" -f 2>&1 || true
    fi
  fi
else
  echo "=== no outer bootc container found in podman ps -a ==="
fi
date -Iseconds
echo "=== end diagnostics ==="
