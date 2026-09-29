#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts. Not meant to be run directly.
#
# VM state lives outside the project in $WTE_HOME (default ~/.config/windows-test-env):
#   $WTE_HOME/keys/                 SSH keypair shared by all VMs
#   $WTE_HOME/current               name of the selected VM
#   $WTE_HOME/<name>/vm.env         VERSION etc. captured when the VM was created
#   $WTE_HOME/<name>/storage/       live VM disk + ISO   (-> /storage)
#   $WTE_HOME/<name>/checkpoint/    sparse copy restored by reset.sh
#   $WTE_HOME/<name>/shared/        -> Z:\ inside Windows
#
# Every script accepts "--vm <name>" (or VM=<name> in the environment) to pick a VM;
# otherwise the current one is used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a
SSH_PORT="${SSH_PORT:-2222}"
WEB_PORT="${WEB_PORT:-8006}"
RDP_PORT="${RDP_PORT:-3389}"
WIN_USERNAME="${WIN_USERNAME:-Docker}"
WIN_PASSWORD="${WIN_PASSWORD:-admin}"
CONTAINER="windows-test-env"
WTE_HOME="${WTE_HOME:-$HOME/.config/windows-test-env}"
SSH_KEY="$WTE_HOME/keys/id_ed25519"
CURRENT_FILE="$WTE_HOME/current"
mkdir -p "$WTE_HOME"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ---------- argument pre-scan: pull out --vm <name>, leave the rest in ARGS ----------
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --vm) shift; VM="${1:-}"; [ -n "$VM" ] || die "--vm needs a name" ;;
        --vm=*) VM="${1#--vm=}" ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

# ---------- VM selection ----------
VM_NAME=""
vm_default_name() { echo "win${VERSION:-11}_$(date +%Y-%m-%d)"; }
vm_exists() { [ -n "${1:-}" ] && [ -d "$WTE_HOME/$1/storage" ]; }
vm_list()   { find "$WTE_HOME" -mindepth 2 -maxdepth 2 -type d -name storage -printf '%h\n' 2>/dev/null | xargs -rn1 basename | sort; }

set_vm() { # set_vm <name>
    VM_NAME="${1:?}"
    VM_DIR="$WTE_HOME/$VM_NAME"
    VM_STORAGE="$VM_DIR/storage"
    VM_SHARED="$VM_DIR/shared"
    CHECKPOINT_DIR="$VM_DIR/checkpoint"
    # shellcheck disable=SC1090
    [ -f "$VM_DIR/vm.env" ] && set -a && . "$VM_DIR/vm.env" && set +a
    export VM_NAME VM_STORAGE VM_SHARED   # consumed by docker-compose.yml
}

create_vm() { # create_vm <name>
    local name="${1:?}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "VM name may only contain letters, digits, '.', '_' and '-'"
    [ -e "$WTE_HOME/$name" ] && die "VM '$name' already exists in $WTE_HOME"
    mkdir -p "$WTE_HOME/$name/storage" "$WTE_HOME/$name/shared"
    printf 'VERSION=%s\nWIN_USERNAME=%s\nWIN_PASSWORD=%s\nCREATED=%s\n' \
        "${VERSION:-11}" "$WIN_USERNAME" "$WIN_PASSWORD" "$(date -Iseconds)" > "$WTE_HOME/$name/vm.env"
    echo "$name" > "$CURRENT_FILE"
    set_vm "$name"
    log "Created VM '$name' in $VM_DIR"
}

use_vm() { vm_exists "${1:-}" || die "No VM named '${1:-}' in $WTE_HOME (see ./vm.sh list)"; echo "$1" > "$CURRENT_FILE"; set_vm "$1"; }

# Select from --vm / $VM / current file. Returns 1 (without dying) if nothing is selected.
select_vm() {
    local name="${VM:-}"
    [ -z "$name" ] && [ -f "$CURRENT_FILE" ] && name="$(cat "$CURRENT_FILE")"
    [ -n "$name" ] || return 1
    vm_exists "$name" || die "VM '$name' not found in $WTE_HOME (see ./vm.sh list)"
    set_vm "$name"
}
require_vm() { select_vm || die "No VM selected. Create one with ./start-with-openssh.sh --new, or pick one with ./vm.sh use <name>"; }

# The single container can only serve one VM at a time; make sure it's ours.
container_vm() { docker inspect -f '{{index .Config.Labels "windows-test-env.vm"}}' "$CONTAINER" 2>/dev/null || true; }
ensure_container_matches_vm() {
    local other; other="$(container_vm)"
    if [ -z "$other" ] || [ "$other" = "$VM_NAME" ]; then return 0; fi
    if container_running; then
        die "VM '$other' is currently running in the container. Run ./stop.sh first."
    fi
    log "Removing stopped container that belonged to VM '$other'"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

# ---------- Guacamole (web RDP) ----------
GUAC_HOME="$WTE_HOME/guac"
export GUAC_HOME
# Renders user-mapping.xml (Guacamole's file-based auth) with an RDP and a VNC connection to the VM.
ensure_guac_config() {
    mkdir -p "$GUAC_HOME"
    local u="${GUAC_USER:-admin}" p="${GUAC_PASSWORD:-admin}"
    cat > "$GUAC_HOME/user-mapping.xml" <<XML
<user-mapping>
  <authorize username="$u" password="$p">
    <connection name="Windows - RDP (${VM_NAME:-vm})">
      <protocol>rdp</protocol>
      <param name="hostname">windows</param>
      <param name="port">3389</param>
      <param name="username">$WIN_USERNAME</param>
      <param name="password">$WIN_PASSWORD</param>
      <param name="ignore-cert">true</param>
      <param name="security">any</param>
      <param name="resize-method">display-update</param>
      <param name="enable-audio">true</param>
      <param name="enable-drive">true</param>
      <param name="drive-name">Shared</param>
      <param name="drive-path">/drive</param>
      <param name="create-drive-path">true</param>
    </connection>
    <connection name="Windows - console VNC (${VM_NAME:-vm})">
      <protocol>vnc</protocol>
      <param name="hostname">windows</param>
      <param name="port">5900</param>
    </connection>
  </authorize>
</user-mapping>
XML
}

# ---------- SSH ----------
ensure_keys() {
    mkdir -p "$WTE_HOME/keys" oem
    if [ ! -f "$SSH_KEY" ]; then
        log "Generating SSH keypair $SSH_KEY"
        ssh-keygen -q -t ed25519 -N '' -C 'windows-test-env' -f "$SSH_KEY"
    fi
    # Baked into C:\OEM at install time and installed as administrators_authorized_keys.
    cp "$SSH_KEY.pub" oem/authorized_keys
}

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR -o BatchMode=yes)

# Run a PowerShell command inside the VM: wssh 'Get-Service sshd'
wssh() { ssh "${SSH_OPTS[@]}" "$WIN_USERNAME@127.0.0.1" "$@"; }
# Copy to/from VM: wscp ./file "win:C:/WinTestEnv/"   (use win: as the remote prefix)
wscp() {
    local args=()
    for a in "$@"; do args+=("${a/#win:/$WIN_USERNAME@127.0.0.1:}"); done
    scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o BatchMode=yes "${args[@]}"
}

ssh_up() { wssh 'exit 0' >/dev/null 2>&1; }

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]
}

# wait_for_ssh <timeout-seconds>
wait_for_ssh() {
    local timeout="${1:-600}" start=$SECONDS
    while ! ssh_up; do
        if (( SECONDS - start > timeout )); then return 1; fi
        container_running || die "Container $CONTAINER is not running. Check: docker logs $CONTAINER"
        sleep 10
    done
}

# wait_for_ssh_down <timeout-seconds>  (used around reboots)
wait_for_ssh_down() {
    local timeout="${1:-300}" start=$SECONDS
    while ssh_up; do
        if (( SECONDS - start > timeout )); then return 1; fi
        sleep 5
    done
}

print_access_info() {
    cat <<INFO

  VM '$VM_NAME' is up and OpenSSH is reachable.   ($VM_DIR)

  SSH:       ssh -i $SSH_KEY -p $SSH_PORT $WIN_USERNAME@127.0.0.1
             (or just:  ./ssh.sh  [command])
  Copy in:   scp -i $SSH_KEY -P $SSH_PORT ./file.exe $WIN_USERNAME@127.0.0.1:C:/Users/$WIN_USERNAME/Desktop/
  Copy out:  scp -i $SSH_KEY -P $SSH_PORT $WIN_USERNAME@127.0.0.1:C:/path/file .
  Shared:    $VM_SHARED  <->  Z:\\ (and "Shared" on the desktop)
  Web RDP:   http://127.0.0.1:${GUAC_PORT:-8080}   (Guacamole, login ${GUAC_USER:-admin} / ${GUAC_PASSWORD:-admin})
  Web:       http://127.0.0.1:$WEB_PORT   (raw console / installer view)
  RDP:       127.0.0.1:$RDP_PORT  user=$WIN_USERNAME pass=$WIN_PASSWORD

INFO
}

# ---------- checkpoints ----------
checkpoint_exists() { [ -f "${CHECKPOINT_DIR:-/nonexistent}/data.img" ]; }

# Copy every VM state file except the installer ISO (kept in storage/, not part of the state).
# data.img is a raw sparse file, so --sparse=always keeps the copy at its allocated size.
_copy_vm_files() { # _copy_vm_files <from> <to>
    local from="${1:?}" to="${2:?}" f
    mkdir -p "$to"
    for f in "$from"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.iso) continue ;; esac
        cp --sparse=always -f "$f" "$to/"
    done
}

save_checkpoint() {
    container_running && die "Stop the VM before checkpointing (disk must be consistent)."
    local tmp="${CHECKPOINT_DIR:?}.tmp"
    rm -rf "${tmp:?}"
    log "Saving checkpoint of '$VM_NAME' ($(du -h "$VM_STORAGE/data.img" | cut -f1) allocated of $(du -h --apparent-size "$VM_STORAGE/data.img" | cut -f1)) ..."
    _copy_vm_files "$VM_STORAGE" "$tmp"
    rm -rf "${CHECKPOINT_DIR:?}"
    mv "$tmp" "$CHECKPOINT_DIR"
    date -Iseconds > "$CHECKPOINT_DIR/created"
    log "Checkpoint saved to $CHECKPOINT_DIR ($(du -sh "$CHECKPOINT_DIR" | cut -f1))"
}

restore_checkpoint() {
    container_running && die "Stop the VM before restoring."
    checkpoint_exists || die "No checkpoint in $CHECKPOINT_DIR"
    log "Restoring '$VM_NAME' from checkpoint taken $(cat "$CHECKPOINT_DIR/created" 2>/dev/null || echo '?') ..."
    local f
    for f in "${VM_STORAGE:?}"/*; do
        [ -e "$f" ] || continue
        case "$f" in *.iso) continue ;; esac
        rm -f "$f"
    done
    _copy_vm_files "$CHECKPOINT_DIR" "$VM_STORAGE"
    rm -f "$VM_STORAGE/created"
    log "Restored."
}
