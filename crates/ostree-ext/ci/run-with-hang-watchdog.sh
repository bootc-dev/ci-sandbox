#!/bin/bash
# Run a command in the background, and if its stdout+stderr stop growing
# for STALL_SECS (or it runs past MAX_SECS total), assume it's hung: dump
# diagnostics (see dump-hang-diagnostics.sh) while the hang is still live,
# then kill it and exit non-zero. This exists to reproduce/diagnose the
# bootc PR #2394 "chunkah hang" without needing an interactive session to
# be attached at exactly the right moment.
#
# Usage: run-with-hang-watchdog.sh <logfile> <stall_secs> <max_secs> -- <command...>
set -euo pipefail

logfile=$1; stall_secs=$2; max_secs=$3
shift 3
if [ "${1:-}" != "--" ]; then
    echo "usage: $0 <logfile> <stall_secs> <max_secs> -- <command...>" 1>&2
    exit 2
fi
shift

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"$@" > "$logfile" 2>&1 &
run_pid=$!

start=$(date +%s); last_size=0; last_change=$start
while kill -0 "$run_pid" 2>/dev/null; do
    sleep 15
    now=$(date +%s)
    size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    if [ "$size" != "$last_size" ]; then last_size=$size; last_change=$now; fi
    elapsed=$((now - start)); stalled=$((now - last_change))
    echo "watchdog: elapsed=${elapsed}s stalled=${stalled}s logsize=${size}"
    if [ "$stalled" -ge "$stall_secs" ] || [ "$elapsed" -ge "$max_secs" ]; then
        {
            echo "=== HANG DETECTED (stalled ${stalled}s, elapsed ${elapsed}s) ==="
            echo '```'
            sudo bash "${script_dir}/dump-hang-diagnostics.sh" "$logfile" 2>&1
            echo '```'
        } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
        kill -9 "$run_pid" 2>/dev/null || true
        echo "--- tail of command log at hang time ---"
        tail -200 "$logfile"
        exit 1
    fi
done

rc=0
wait "$run_pid" || rc=$?
echo "--- command log ---"
cat "$logfile"
exit "$rc"
