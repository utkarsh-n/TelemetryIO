#!/bin/zsh
# A bounded experiment for the observed CoreSimulator GCD worker starvation.
# It never signals, restarts, boots, or shuts down a process or simulator.
set -euo pipefail

if (( EUID != 0 )); then
    print -u2 'Administrator access is required to change the kernel worker limit.'
    exit 1
fi

original_thread_limit=$(/usr/sbin/sysctl -n kern.wq_max_constrained_threads)
hard_thread_limit=$(/usr/sbin/sysctl -n kern.wq_max_threads)
target_thread_limit=80
if [[ "$original_thread_limit" != 64 ]] || (( hard_thread_limit < target_thread_limit )); then
    print -u2 "Unexpected worker limits: constrained=$original_thread_limit total=$hard_thread_limit. Nothing changed."
    exit 2
fi

restore_worker_limit() {
    recovery_exit_code=$?
    trap - EXIT
    trap '' INT TERM HUP
    if ! /usr/sbin/sysctl -w "kern.wq_max_constrained_threads=$original_thread_limit"; then
        print -u2 "Restoration failed: could not write original worker limit $original_thread_limit."
        exit 3
    fi
    if ! restored_thread_limit=$(/usr/sbin/sysctl -n kern.wq_max_constrained_threads); then
        print -u2 'Restoration could not be verified: worker-limit readback failed.'
        exit 3
    fi
    if [[ "$restored_thread_limit" != "$original_thread_limit" ]]; then
        print -u2 "Restoration failed: expected $original_thread_limit, read $restored_thread_limit."
        exit 3
    fi
    print "Restored constrained worker limit to $restored_thread_limit."
    exit "$recovery_exit_code"
}
trap restore_worker_limit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

print 'Temporarily allowing 80 constrained workers for 15 seconds; no simulator will be restarted by this script.'
/usr/sbin/sysctl -w "kern.wq_max_constrained_threads=$target_thread_limit"
/bin/sleep 15
