#!/usr/bin/env bash
# Gracefully shuts down Windows (ACPI shutdown, up to 2 min) and removes the container.
# The VM disk is kept; ./start-with-openssh.sh boots it again.
. "$(dirname "$0")/lib.sh"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "Container $CONTAINER does not exist - nothing to stop."
    exit 0
fi
running="$(container_vm)"
if vm_exists "$running"; then set_vm "$running"; else select_vm || true; fi
log "Stopping VM '${running:-?}' (graceful shutdown, may take up to 2 minutes) ..."
if [ -n "${VM_STORAGE:-}" ]; then
    docker compose down
else
    docker stop -t 120 "$CONTAINER" >/dev/null && docker rm "$CONTAINER" >/dev/null
    docker rm -f windows-test-env-guac windows-test-env-guacd >/dev/null 2>&1 || true
fi
log "Stopped."
