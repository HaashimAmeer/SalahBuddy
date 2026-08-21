#!/bin/sh
# Boot a simulator, bounded — and recover from one that has wedged.
#
# Why this exists: three ios runs have died to the same stall. `simctl
# bootstatus -b` reports
#
#     Status=1, isTerminal=NO, Elapsed=00:05
#         Waiting on BackBoard
#
# and then waits FOREVER. bootstatus names the stall, which is worth having,
# but it has no timeout of its own, so a wedged simulator costs the entire job
# timeout and reports nothing but "The operation was canceled."
#
# So: bound the wait with a watchdog, and on a timeout ERASE the device and try
# once more. "Waiting on BackBoard" is what a stale or half-written simulator
# state looks like, and erasing is what clears it.
#
# The erase is CI-ONLY. Wiping a developer's simulator — their installed apps,
# their granted permissions, their logged-in state — to save a CI minute would
# be a rotten trade, so locally this only ever boots and waits.
set -eu

SIM_ID="${1:?usage: boot_sim.sh <simulator-udid>}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-240}"

wait_for_boot() {
    # `bootstatus -b` boots if needed and blocks until the device is usable.
    # Backgrounded under a watchdog because it will otherwise never return.
    xcrun simctl bootstatus "$SIM_ID" -b &
    boot_pid=$!
    ( sleep "$BOOT_TIMEOUT"; kill -9 "$boot_pid" 2>/dev/null ) &
    watchdog_pid=$!

    if wait "$boot_pid" 2>/dev/null; then
        kill -9 "$watchdog_pid" 2>/dev/null || true
        return 0
    fi
    kill -9 "$watchdog_pid" 2>/dev/null || true
    return 1
}

if wait_for_boot; then
    echo "▸ Simulator ready."
    exit 0
fi

echo "✗ Simulator did not finish booting within ${BOOT_TIMEOUT}s (the classic"
echo "  'Waiting on BackBoard' wedge)."

if [ -z "${CI:-}" ]; then
    echo "  Not erasing: this is a local machine, and erasing would wipe your"
    echo "  simulator's apps, permissions and logins. Try:"
    echo "      xcrun simctl shutdown $SIM_ID && xcrun simctl erase $SIM_ID"
    exit 1
fi

echo "▸ CI: erasing the device and retrying once."
xcrun simctl shutdown "$SIM_ID" 2>/dev/null || true
xcrun simctl erase "$SIM_ID" 2>/dev/null || true

if wait_for_boot; then
    echo "▸ Simulator ready after erase."
    exit 0
fi

echo "✗ Still wedged after an erase — this runner's simulator is unusable."
exit 1
