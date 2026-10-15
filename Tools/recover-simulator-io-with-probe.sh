#!/bin/zsh
# Temporary worker-limit experiment with one bounded, read-only metadata RPC.
# No service/simulator restarts. Python times out only its fresh simctl child.
set -euo pipefail
unsetopt BG_NICE

if (( EUID != 0 )); then
    print -u2 'Run this script through sudo from your own Terminal account.'
    exit 1
fi
if [[ -z "${SUDO_USER-}" || "${SUDO_USER-}" == root || "${SUDO_UID-}" != <-> ]]; then
    print -u2 'A non-root original SUDO_USER and numeric SUDO_UID are required.'
    exit 2
fi
if ! recovery_caller_uid=$(/usr/bin/id -u -- "$SUDO_USER"); then
    print -u2 'The original sudo account could not be resolved.'
    exit 2
fi
if [[ "$recovery_caller_uid" != "$SUDO_UID" ]] || (( recovery_caller_uid == 0 )); then
    print -u2 'The original sudo account does not match SUDO_UID. Nothing changed.'
    exit 2
fi

target_thread_limit="${1-80}"
if (( $# > 1 )) || [[ "$target_thread_limit" != 80 && "$target_thread_limit" != 128 ]]; then
    print -u2 'Usage: recover-simulator-io-with-probe.sh [80|128]. Nothing changed.'
    exit 2
fi

zmodload zsh/datetime
recovery_log=$(/usr/bin/mktemp /tmp/TelemetryIO-worker-recovery.XXXXXX)
/bin/chmod 644 "$recovery_log"
exec {recovery_log_fd}>> "$recovery_log"
recovery_note() { print -u "$recovery_log_fd" -- "$EPOCHREALTIME $*"; }
print "Recovery log: $recovery_log"
recovery_note "caller_uid=$recovery_caller_uid"

original_thread_limit=$(/usr/sbin/sysctl -n kern.wq_max_constrained_threads)
hard_thread_limit=$(/usr/sbin/sysctl -n kern.wq_max_threads)
recovery_note "before constrained=$original_thread_limit total=$hard_thread_limit"
if [[ "$original_thread_limit" != 64 || "$hard_thread_limit" != <-> ]] || (( hard_thread_limit < target_thread_limit )); then
    recovery_note 'unexpected_limits nothing_changed'
    print -u2 "Expected constrained=64 and total>=$target_thread_limit. Nothing changed."
    exit 2
fi

restore_worker_limit() {
    recovery_exit_code=$?
    trap - EXIT
    trap '' INT TERM HUP
    recovery_note "restoring constrained=$original_thread_limit prior_exit=$recovery_exit_code"
    if ! /usr/sbin/sysctl -w "kern.wq_max_constrained_threads=$original_thread_limit" >& "$recovery_log_fd" 2>&1; then
        recovery_note 'restore_write_failed'
        print -u2 "Restoration failed. Check $recovery_log; expected constrained=64."
        exit 3
    fi
    if ! restored_thread_limit=$(/usr/sbin/sysctl -n kern.wq_max_constrained_threads); then
        recovery_note 'restore_readback_failed'
        print -u2 "Restoration could not be verified. Check $recovery_log."
        exit 3
    fi
    recovery_note "restored_readback constrained=$restored_thread_limit"
    if [[ "$restored_thread_limit" != "$original_thread_limit" ]]; then
        print -u2 "Restoration mismatch. Check $recovery_log; expected constrained=64."
        exit 3
    fi
    print "Restored constrained worker limit to $restored_thread_limit. Log: $recovery_log"
    exit "$recovery_exit_code"
}
trap restore_worker_limit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/usr/sbin/sysctl -w "kern.wq_max_constrained_threads=$target_thread_limit" >& "$recovery_log_fd" 2>&1
recovery_window_started=$EPOCHREALTIME
# This timer belongs to the parent. A blocked RPC cannot extend the window.
/bin/sleep 15 &
recovery_timer_pid=$!
raised_thread_limit=$(/usr/sbin/sysctl -n kern.wq_max_constrained_threads)
recovery_note "raised_readback constrained=$raised_thread_limit window_started=$recovery_window_started seconds=15"
if [[ "$raised_thread_limit" != "$target_thread_limit" ]]; then
    recovery_note 'raise_readback_mismatch'
    exit 3
fi

# asuser supplies the caller's bootstrap/audit context; sudo supplies UID/GID
# and home. Isolated system Python cannot load user site/customization modules.
# Disown the wrapper: parent restoration never waits for bootstrap/sudo startup.
/bin/launchctl asuser "$SUDO_UID" /usr/bin/sudo -n -H -u "$SUDO_USER" \
    /usr/bin/python3 -I -S - "$SUDO_UID" >& "$recovery_log_fd" 2>&1 <<'PY' &!
import ctypes
import json
import os
import subprocess
import sys
import time

OWNED_UUIDS = ("811304CF-E8CB-4128-8B0A-9A8BA07A86D9", "A104A418-5F8B-4700-A731-14CD937A7EEB")
SERVICE_SUFFIX = "/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService"

def note(message):
    print(f"{time.time():.6f} {message}", flush=True)

def workqueue(label):
    try:
        candidates = subprocess.run(
            ["/usr/bin/pgrep", "-u", str(os.getuid()), "-f", r"/CoreSimulator\.framework/Versions/[^/]+/XPCServices/com\.apple\.CoreSimulator\.CoreSimulatorService\.xpc/Contents/MacOS/com\.apple\.CoreSimulator\.CoreSimulatorService( |$)"],
            capture_output=True, text=True, timeout=1,
        )
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        libproc.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
        libproc.proc_pidpath.restype = ctypes.c_int
        libproc.proc_pidinfo.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
        libproc.proc_pidinfo.restype = ctypes.c_int
        class Workqueue(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint32) for name in ("threads", "running", "blocked", "state")]
        found = False
        for candidate in candidates.stdout.split():
            if not candidate.isdecimal():
                continue
            pid = int(candidate)
            executable = ctypes.create_string_buffer(4096)
            if libproc.proc_pidpath(pid, executable, len(executable)) <= 0:
                continue
            path = executable.value.decode("utf-8", "replace")
            if "/CoreSimulator.framework/Versions/" not in path or not path.endswith(SERVICE_SUFFIX):
                continue
            info = Workqueue()
            count = libproc.proc_pidinfo(pid, 12, 0, ctypes.byref(info), ctypes.sizeof(info))
            if count == ctypes.sizeof(info):
                note(f"workqueue_{label} pid={pid} threads={info.threads} running={info.running} blocked={info.blocked} state={info.state} constrained_limit_reached={bool(info.state & 1)}")
            else:
                note(f"workqueue_{label} pid={pid} unavailable errno={ctypes.get_errno()}")
            found = True
        if not found:
            note(f"workqueue_{label} service_not_found_or_unreadable")
    except Exception as error:
        note(f"workqueue_{label} unavailable type={type(error).__name__}")

if os.getuid() != int(sys.argv[1]) or os.getuid() == 0:
    note("probe_identity_mismatch no_rpc_started")
    sys.exit(2)
note(f"probe_uid={os.getuid()}")
workqueue("before_rpc")
rpc_exit = 1
try:
    result = subprocess.run(["/usr/bin/xcrun", "simctl", "list", "devices", "--json"], capture_output=True, text=True, timeout=5)
    rpc_exit = result.returncode
    note(f"metadata_rpc_exit={rpc_exit} stderr_bytes={len(result.stderr.encode('utf-8'))}")
    if rpc_exit == 0:
        metadata = json.loads(result.stdout)
        states = {uuid: "not_listed" for uuid in OWNED_UUIDS}
        for devices in metadata.get("devices", {}).values():
            for device in devices:
                uuid = device.get("udid", "").upper()
                if uuid in states:
                    state = device.get("state")
                    states[uuid] = state[:40] if isinstance(state, str) else "unrecognized_state"
        note("owned_device_states=" + json.dumps(states, sort_keys=True))
except subprocess.TimeoutExpired:
    rpc_exit = 124
    note("metadata_rpc_exit=124 timed_out_after=5 fresh_client_killed_by_subprocess_run")
except Exception as error:
    rpc_exit = 1
    note(f"metadata_rpc_error type={type(error).__name__}")
finally:
    time.sleep(1)
    workqueue("after_rpc")
    note(f"probe_complete rpc_exit={rpc_exit}")
sys.exit(0 if rpc_exit == 0 else 1)
PY
recovery_note "probe_wrapper_pid=$! parent_restore_independent=true"
print "Worker limit is temporarily $target_thread_limit. The metadata RPC times out after five seconds; restoration is scheduled after 15 seconds."
if wait "$recovery_timer_pid"; then
    recovery_note 'window_elapsed no_probe_wait'
else
    recovery_timer_exit=$?
    recovery_note "timer_exit=$recovery_timer_exit"
    exit "$recovery_timer_exit"
fi
exit 0
