#!/usr/bin/env bash
# Resets a VM to its saved checkpoint (see ./checkpoint.sh). Falls back to a full
# reinstall when no checkpoint exists.
# Usage: ./reset.sh [--vm <name>] [-y] [--full] [--no-start] [--keep-shared]
#   -y            don't ask for confirmation
#   --full        ignore the checkpoint and reinstall Windows from scratch
#   --no-start    only reset; don't start the VM afterwards
#   --keep-shared keep the contents of the VM's shared folder
. "$(dirname "$0")/lib.sh"

YES=0; START=1; FULL=0; KEEP_SHARED=0
for a in "${ARGS[@]}"; do
    case "$a" in
        -y|--yes) YES=1 ;;
        --full) FULL=1 ;;
        --no-start) START=0 ;;
        --keep-shared) KEEP_SHARED=1 ;;
        *) die "Unknown option: $a" ;;
    esac
done
require_vm

if (( ! FULL )) && checkpoint_exists; then
    MODE=checkpoint
    what="restore VM '$VM_NAME' to the checkpoint from $(cat "$CHECKPOINT_DIR/created" 2>/dev/null || echo '?')"
else
    MODE=full
    (( FULL )) || warn "No checkpoint for '$VM_NAME' - doing a full reinstall."
    what="DELETE the disk of VM '$VM_NAME' and reinstall Windows"
fi
(( KEEP_SHARED )) || what="$what and wipe its shared folder"

if (( ! YES )); then
    echo "This will $what."
    read -r -p "Continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

ensure_container_matches_vm
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "Stopping container ..."
    docker compose down -t 30
fi

# Deletes the contents of a VM sub-directory. Files may be root-owned if the container
# ran as root; in that case fall back to deleting through a throwaway container.
wipe_dir() { # wipe_dir <dir> <keep-iso 0|1>
    local dir="${1:?}" keep="${2:?}" ok=1 f
    case "$dir" in "$WTE_HOME"/*/*) ;; *) die "refusing to wipe $dir" ;; esac
    mkdir -p "$dir"
    for f in "$dir"/* "$dir"/.[!.]*; do
        [ -e "$f" ] || continue
        if [ "$keep" = 1 ] && [ "${f%.iso}" != "$f" ]; then continue; fi
        rm -rf "${f:?}" 2>/dev/null || ok=0
    done
    if (( ! ok )); then
        log "Permission denied on some files - wiping via container"
        docker run --rm -v "$dir:/s" -e KEEP_ISO="$keep" alpine sh -c '
            cd /s && for f in * .[!.]*; do
                [ -e "$f" ] || continue
                if [ "$KEEP_ISO" = 1 ] && [ "${f%.iso}" != "$f" ]; then continue; fi
                rm -rf "$f"
            done'
    fi
}

if [ "$MODE" = checkpoint ]; then
    restore_checkpoint
else
    log "Wiping $VM_STORAGE (keeping the ISO to avoid re-downloading)"
    wipe_dir "$VM_STORAGE" 1
fi
if (( ! KEEP_SHARED )); then
    log "Wiping $VM_SHARED"
    wipe_dir "$VM_SHARED" 0
fi

if (( START )); then
    exec "$ROOT/start-with-openssh.sh" --vm "$VM_NAME"
else
    log "Reset complete. Run ./start-with-openssh.sh --vm $VM_NAME to boot."
fi
