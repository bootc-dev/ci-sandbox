#!/bin/bash
# Poll the (shared, --pid=host) host PID namespace for the chunkah `podman
# run` client process -- the podman invocation that creates the nested
# chunkah build container -- and, once found, capture its mnt/ipc namespace
# identifiers for comparison against the outer bootc container's own
# entrypoint namespace and against host PID 1.
#
# This is the "no host-namespace-escape" verification for the
# repro-chunkah-no-host-systemd.yml experiment (bootc PR #2394
# investigation): with systemd-run removed AND the host's /run/systemd,
# /run/dbus no longer bind-mounted into the outer container, the chunkah
# `podman run` process should be a plain fork/exec child of the script
# running as the outer container's own entrypoint, and should therefore
# share that container's own (non-host) mnt/ipc namespaces -- not the
# host's. Reuses the exact comparison technique from
# dump-hang-diagnostics.sh (commit 154e1303).
#
# Meant to be launched in the background (via `&`) just before running the
# repro script, then `wait`ed on after the repro script finishes.
#
# Usage: capture-chunkah-ns.sh <output-file> [timeout-secs]
set -uo pipefail
out="${1:?usage: $0 <output-file> [timeout-secs]}"
timeout_secs="${2:-600}"

find_chunkah_run_pid() {
    local pid argv joined
    for pid in /proc/[0-9]*; do
        pid=${pid##*/}
        [ -r "/proc/$pid/cmdline" ] || continue
        mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || continue
        joined="${argv[*]:-}"
        if [[ "${argv[0]:-}" == */podman || "${argv[0]:-}" == "podman" ]] \
            && [[ "$joined" == *"run"* ]] && [[ "$joined" == *"chunkah"* ]]; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

start=$(date +%s)
pid=""
while :; do
    pid=$(find_chunkah_run_pid || true)
    [ -n "$pid" ] && break
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_secs" ]; then
        echo "TIMEOUT: never observed a chunkah 'podman run' process within ${timeout_secs}s (script may have failed before reaching that step)" >"$out"
        exit 0
    fi
    sleep 1
done

{
    echo "=== found chunkah podman run pid=$pid ==="
    ps -o pid,ppid,args -p "$pid" 2>&1

    chunkah_mnt=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null || echo "")
    chunkah_ipc=$(readlink "/proc/$pid/ns/ipc" 2>/dev/null || echo "")
    echo "--- chunkah run pid=$pid ns/mnt=$chunkah_mnt ns/ipc=$chunkah_ipc ---"

    host_mnt=$(readlink /proc/1/ns/mnt 2>/dev/null || echo "")
    host_ipc=$(readlink /proc/1/ns/ipc 2>/dev/null || echo "")
    echo "--- host pid 1 ns/mnt=$host_mnt ns/ipc=$host_ipc ---"

    outer_id=$(podman ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null | grep -m1 bootc | awk '{print $1}' || true)
    outer_pid=""
    if [ -n "$outer_id" ]; then
        outer_pid=$(podman inspect -f '{{.State.Pid}}' "$outer_id" 2>/dev/null || echo "")
    fi
    outer_mnt=""; outer_ipc=""
    if [ -n "$outer_pid" ] && [ "$outer_pid" != "0" ]; then
        outer_mnt=$(readlink "/proc/$outer_pid/ns/mnt" 2>/dev/null || echo "")
        outer_ipc=$(readlink "/proc/$outer_pid/ns/ipc" 2>/dev/null || echo "")
        echo "--- outer container entrypoint pid=$outer_pid (id=$outer_id) ns/mnt=$outer_mnt ns/ipc=$outer_ipc ---"
    else
        echo "--- could not resolve outer container pid (outer_id='$outer_id') ---"
    fi

    echo "--- comparison ---"
    if [ -n "$chunkah_mnt" ] && [ "$chunkah_mnt" = "$host_mnt" ]; then
        echo "MNT: chunkah podman run process is in the HOST's mnt namespace -- ESCAPE"
    else
        echo "MNT: chunkah podman run process mnt namespace differs from host's -- no escape via mnt"
    fi
    if [ -n "$chunkah_ipc" ] && [ "$chunkah_ipc" = "$host_ipc" ]; then
        echo "IPC: chunkah podman run process is in the HOST's ipc namespace -- ESCAPE"
    else
        echo "IPC: chunkah podman run process ipc namespace differs from host's -- no escape via ipc"
    fi
    if [ -n "$outer_mnt" ]; then
        if [ "$chunkah_mnt" = "$outer_mnt" ]; then
            echo "MNT: chunkah podman run process matches the OUTER CONTAINER's own mnt namespace -- expected/correct"
        else
            echo "MNT: chunkah podman run process does NOT match the outer container's own mnt namespace"
        fi
    fi
    if [ -n "$outer_ipc" ]; then
        if [ "$chunkah_ipc" = "$outer_ipc" ]; then
            echo "IPC: chunkah podman run process matches the OUTER CONTAINER's own ipc namespace -- expected/correct"
        else
            echo "IPC: chunkah podman run process does NOT match the outer container's own ipc namespace"
        fi
    fi
} >"$out" 2>&1
