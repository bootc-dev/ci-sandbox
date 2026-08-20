#!/bin/bash
# Dump diagnostics about the host and any nested podman/outer bootc
# container, for use by a watchdog that suspects a hung chunkah/podman
# step (see repro-chunkah-hang.yml and the AGENTS.md investigation notes
# for bootc PR #2394). Mostly read-only (the strace snippet just
# attaches/detaches briefly), EXCEPT for the final step: sending SIGQUIT
# to the hung `podman info` to force a Go runtime goroutine dump. That
# step is intentionally destructive (it terminates the hung process) and
# must stay last.
#
# NOTE on PID namespaces: the outer container in repro-chunkah-hang.yml is
# started with `--pid=host`, which means every process it (transitively)
# spawns -- including the `podman info` we're chasing here -- lives
# directly in the *host's* PID namespace. There is no need to nsenter
# into the container's PID namespace to see or ptrace these processes;
# doing so was actually the bug in an earlier version of this script (it
# nsentered into the container's *mount* namespace to run strace, where
# strace isn't installed, and also matched the wrong process -- the
# `podman run`/`systemd-run` wrapper instead of the actual `podman info`
# child). ptrace works fine across mount namespaces as long as we have
# CAP_SYS_PTRACE and share a PID namespace with the target, which is
# exactly the case here.
set -x
date -Iseconds

# Optional: path to the watchdog's captured stdout+stderr log for the
# command tree that contains the hung `podman info` (see run-with-hang-watchdog.sh,
# which passes its own $logfile as $1). Used at the very end of this script
# to check whether a SIGQUIT-triggered Go goroutine dump propagated there.
WATCHDOG_LOGFILE="${1:-}"

# --- Locate the actual "podman info" process precisely -------------------
# Match strictly on argv via /proc/<pid>/cmdline: exactly two arguments,
# argv[0] a path ending in "podman", argv[1] == "info". This is careful to
# avoid matching:
#  - the `systemd-run -dP --wait podman info` wrapper (argv[0] is
#    systemd-run, not podman)
#  - `podman run ...` (the outer wrapper container, or the chunkah build)
#  - stray `podman pull` / `podman inspect` processes that may be running
#    concurrently earlier/later in the script
find_podman_info_pid() {
  local pid argv
  for pid in /proc/[0-9]*; do
    pid=${pid##*/}
    [ -r "/proc/$pid/cmdline" ] || continue
    argv=()
    mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || continue
    if [ "${#argv[@]}" -eq 2 ] && [[ "${argv[0]}" == */podman || "${argv[0]}" == "podman" ]] && [ "${argv[1]}" = "info" ]; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

echo "=== searching host PID namespace for the exact 'podman info' process ==="
PODMAN_INFO_PID=$(find_podman_info_pid || true)
if [ -z "${PODMAN_INFO_PID:-}" ]; then
  echo "=== no exact 'podman info' process found (argv == [.../podman, info]) ==="
  echo "=== all processes with comm=podman, for context ==="
  ps -eo pid,ppid,stat,comm,args --no-headers | awk '$4=="podman"'
else
  echo "=== found: podman info pid=$PODMAN_INFO_PID ==="
  ps -o pid,ppid,stat,wchan:32,args -p "$PODMAN_INFO_PID" || true

  echo "--- systemd unit wrapping this pid (systemd-run -dP --wait podman info) ---"
  UNIT=""
  while read -r u; do
    [ -n "$u" ] || continue
    mp=$(systemctl show -p MainPID --value "$u" 2>/dev/null || echo "")
    if [ "$mp" = "$PODMAN_INFO_PID" ]; then
      UNIT="$u"
      break
    fi
  done < <(systemctl list-units 'run-*' --no-pager --plain --no-legend 2>/dev/null | awk '{print $1}')
  if [ -n "$UNIT" ]; then
    systemctl status "$UNIT" --no-pager 2>&1 || true
  else
    echo "(no matching run-*.service unit found for pid $PODMAN_INFO_PID)"
  fi

  echo "--- /proc/$PODMAN_INFO_PID/status ---"
  cat "/proc/$PODMAN_INFO_PID/status" 2>&1

  echo "--- /proc/$PODMAN_INFO_PID/wchan (main thread only) ---"
  cat "/proc/$PODMAN_INFO_PID/wchan" 2>&1; echo

  echo "--- /proc/$PODMAN_INFO_PID/stack (may require elevated perms/CONFIG_STACKTRACE) ---"
  sudo cat "/proc/$PODMAN_INFO_PID/stack" 2>&1

  echo "--- wchan across ALL threads (podman is a multi-threaded Go binary; the blocked goroutine's OS thread may not be the main one) ---"
  for t in "/proc/$PODMAN_INFO_PID"/task/*/wchan; do
    [ -r "$t" ] || continue
    tid=$(basename "$(dirname "$t")")
    printf 'tid=%s wchan=' "$tid"
    cat "$t" 2>&1
    echo
  done

  echo "--- open fds ---"
  ls -l "/proc/$PODMAN_INFO_PID/fd" 2>&1

  echo "--- /proc/$PODMAN_INFO_PID/net/tcp + tcp6 (sockets in this process's netns; ESTABLISHED/SYN_SENT rows = live network I/O, e.g. registry/DNS calls) ---"
  cat "/proc/$PODMAN_INFO_PID/net/tcp" 2>&1
  cat "/proc/$PODMAN_INFO_PID/net/tcp6" 2>&1

  echo "--- lslocks (flock/fcntl locks system-wide; look for containers-storage db/lock paths) ---"
  sudo lslocks 2>&1 || true

  if command -v strace >/dev/null 2>&1; then
    echo "--- strace -p $PODMAN_INFO_PID -f -tt for ~12s (direct on host, no nsenter: ptrace works across mount namespaces given --pid=host + CAP_SYS_PTRACE) ---"
    sudo timeout 12 strace -p "$PODMAN_INFO_PID" -f -tt -o /var/tmp/strace-hang.out
    echo "--- strace output (/var/tmp/strace-hang.out) ---"
    cat /var/tmp/strace-hang.out 2>&1
  else
    echo "!!! strace not installed on host runner -- cannot capture a syscall trace this run."
    echo "!!! Add 'sudo apt-get install -y strace' as a workflow step to fix this."
  fi

  # --- LAST resort / destructive: force a Go runtime goroutine dump -------
  # All prior diagnostics above are passive/read-only. This one is not: Go
  # binaries that don't install their own SIGQUIT handler (podman doesn't)
  # respond to SIGQUIT by having the runtime print every goroutine's stack
  # trace to stderr and then terminate the process. That's exactly what we
  # want to pin down *which* internal wait (mutex/channel/waitgroup) the
  # hang is stuck on, but it does kill the hung process, so this must run
  # after everything else that needs the process still alive.
  #
  # `podman info` here was launched via `systemd-run -dP --wait podman info`
  # inside repro-chunkah-only.sh. The `-P`/`--pipe` flag makes systemd-run
  # forward the transient unit's stdout/stderr back through its own
  # stdout/stderr, which is in turn inherited by the outer `podman run`
  # container and ultimately redirected by run-with-hang-watchdog.sh into
  # $WATCHDOG_LOGFILE. So the goroutine dump *should* land there. Confirm
  # that empirically rather than assuming it, and also check the journal
  # (systemd separately archives transient-unit output there by unit name)
  # as a fallback/supplement.
  echo "--- sending SIGQUIT to podman info pid=$PODMAN_INFO_PID to force a Go runtime goroutine dump (DESTRUCTIVE: process will exit after this) ---"
  sudo kill -QUIT "$PODMAN_INFO_PID" 2>&1 || echo "(kill -QUIT failed, pid may already be gone)"
  sleep 5

  echo "--- confirming pid=$PODMAN_INFO_PID is actually gone (proof the signal was delivered and had effect) ---"
  if ps -p "$PODMAN_INFO_PID" -o pid,stat,args --no-headers 2>/dev/null; then
    echo "!!! pid=$PODMAN_INFO_PID is STILL PRESENT after SIGQUIT + 5s sleep"
  else
    echo "pid=$PODMAN_INFO_PID is gone: SIGQUIT was delivered and the process exited"
  fi

  if [ -n "$WATCHDOG_LOGFILE" ] && [ -r "$WATCHDOG_LOGFILE" ]; then
    echo "--- tail -300 of watchdog logfile ($WATCHDOG_LOGFILE): goroutine dump should appear here if the systemd-run -P pipe propagated it ---"
    tail -300 "$WATCHDOG_LOGFILE" 2>&1
  else
    echo "(no readable watchdog logfile passed as \$1 to this script; got: '${WATCHDOG_LOGFILE:-<empty>}')"
  fi

  echo "--- fallback/supplement: journalctl for run-*.service transient units (systemd archives their stdout/stderr to the journal by unit name too) ---"
  sudo journalctl -u 'run-*' --no-pager -o cat 2>&1 | tail -300
fi

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
  fi
else
  echo "=== no outer bootc container found in podman ps -a ==="
fi
date -Iseconds
echo "=== end diagnostics ==="
