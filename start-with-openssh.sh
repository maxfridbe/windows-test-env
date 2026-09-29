#!/usr/bin/env bash
# Starts a Windows VM (installing it on first run) and waits until OpenSSH answers.
# After a fresh install it saves a clean checkpoint that ./reset.sh restores.
#
# Usage: ./start-with-openssh.sh [--vm <name>] [--new [--name <name>]] [--no-wait] [--no-checkpoint]
#   --new           create a new VM (default name: win<VERSION>_<date>, e.g. win11_2026-09-29)
#   --vm <name>     start an existing VM instead of the current one
. "$(dirname "$0")/lib.sh"

WAIT=1; AUTO_CP=1; NEW=0; NAME=""
set -- "${ARGS[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-wait) WAIT=0 ;;
        --no-checkpoint) AUTO_CP=0 ;;
        --new) NEW=1 ;;
        --name) shift; NAME="${1:-}" ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done
[ -e /dev/kvm ] || die "/dev/kvm not found - KVM is required"
[ -r /dev/kvm ] && [ -w /dev/kvm ] || die "No permission on /dev/kvm (add yourself to the kvm group)"

if (( NEW )); then
    create_vm "${NAME:-$(vm_default_name)}"
elif ! select_vm; then
    if [ -z "$(vm_list)" ]; then
        log "No VMs yet - creating one."
        create_vm "${NAME:-$(vm_default_name)}"
    else
        die "No VM selected. Use ./vm.sh use <name> or ./start-with-openssh.sh --vm <name>. Existing: $(vm_list | tr '\n' ' ')"
    fi
fi
ensure_container_matches_vm
ensure_keys
ensure_guac_config
mkdir -p "$VM_STORAGE" "$VM_SHARED"

FIRST_INSTALL=0
ls "$VM_STORAGE"/*.img >/dev/null 2>&1 || FIRST_INSTALL=1

log "Starting VM '$VM_NAME' (VERSION=${VERSION:-11}, RAM=${RAM_SIZE:-8G}, CPU=${CPU_CORES:-4})"
docker compose up -d --quiet-pull
container_running || die "Container failed to start. See: docker logs $CONTAINER"

if (( FIRST_INSTALL )); then
    log "First run: Windows will be downloaded and installed unattended."
    log "Watch progress at http://127.0.0.1:$WEB_PORT - this typically takes 15-40 minutes."
    TIMEOUT=7200
else
    TIMEOUT=900
fi

(( WAIT )) || { log "Not waiting for SSH (--no-wait)."; exit 0; }

log "Waiting for OpenSSH on port $SSH_PORT (timeout ${TIMEOUT}s) ..."
if wait_for_ssh "$TIMEOUT"; then
    if (( FIRST_INSTALL && AUTO_CP )) && ! checkpoint_exists; then
        log "Fresh install finished - saving it as the baseline checkpoint for ./reset.sh"
        docker compose down
        save_checkpoint
        docker compose up -d
        wait_for_ssh 900 || die "SSH did not come back after checkpointing"
    fi
    print_access_info
else
    die "SSH did not come up within ${TIMEOUT}s. Check http://127.0.0.1:$WEB_PORT and 'docker logs $CONTAINER'. Inside the VM, see C:\\OEM\\setup-ssh.log"
fi
