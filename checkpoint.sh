#!/usr/bin/env bash
# Saves the VM disk as the checkpoint that ./reset.sh restores.
# Usage: ./checkpoint.sh [--vm <name>] [--no-restart]     (Windows is shut down gracefully first)
. "$(dirname "$0")/lib.sh"

RESTART=1; [ "${ARGS[0]:-}" = "--no-restart" ] && RESTART=0
require_vm
[ -f "$VM_STORAGE/data.img" ] || die "VM '$VM_NAME' has no disk yet - nothing to checkpoint."

WAS_RUNNING=0
if container_running; then
    [ "$(container_vm)" = "$VM_NAME" ] || die "A different VM ('$(container_vm)') is running."
    WAS_RUNNING=1
    log "Shutting Windows down cleanly before snapshotting ..."
    docker compose down
fi

save_checkpoint
if (( RESTART && WAS_RUNNING )); then
    log "Starting VM again ..."
    exec "$ROOT/start-with-openssh.sh" --vm "$VM_NAME"
fi
